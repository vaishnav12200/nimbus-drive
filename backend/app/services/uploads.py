"""Large-file staging and chunked upload.

The rule this module has to keep is cross-cutting rule 2: **the backend never
persists file bytes.** Everything here writes to one temporary file that is
removed in a ``finally``, on success, failure, and cancellation alike.

Flow for a file over the Bot API's 20 MB ceiling:

1. Stream the request body to ``{temp_dir}/upload-<uuid>``, hashing as it lands.
2. Slice it into 19 MB segments and send each over MTProto, capturing message ids.
3. Write the ``file_chunks`` manifest and mark the row chunked.
4. Delete the temporary file.

If step 2 fails part-way, the chunk messages already in the channel are deleted
before the error propagates — otherwise a retry would leave orphaned garbage in
the user's channel with nothing referencing it.
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import shutil
import uuid
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.errors import (
    PayloadTooLargeError,
    ServiceUnavailableError,
    TelegramFloodWaitError,
)
from app.core.logging import get_logger
from app.models import File, FileChunk
from app.providers import get_provider
from app.providers.base import (
    StorageCredentials,
    StorageProvider,
    StorageRef,
    UploadMetadata,
    UploadResult,
)
from app.providers.telegram import TelegramStorage

log = get_logger(__name__)

READ_CHUNK = 1024 * 1024  # 1 MiB per read while staging
CHUNK_UPLOAD_ATTEMPTS = 3

# Bounds how many large uploads can occupy disk at once. Without it, a handful of
# concurrent 2 GB uploads fills a small VPS and takes the whole API down.
_upload_slots = asyncio.Semaphore(settings.max_concurrent_large_uploads)
SLOT_WAIT_SECONDS = 30


@dataclass
class StagedUpload:
    path: Path
    size: int
    sha256: str


@asynccontextmanager
async def upload_slot() -> AsyncIterator[None]:
    """Reserve one of the concurrent large-upload slots, or fail fast."""
    try:
        await asyncio.wait_for(_upload_slots.acquire(), timeout=SLOT_WAIT_SECONDS)
    except TimeoutError as exc:
        raise ServiceUnavailableError(
            "Too many large uploads are in flight; retry shortly",
            code="UPLOAD_CAPACITY",
            headers={"Retry-After": "30"},
        ) from exc
    try:
        yield
    finally:
        _upload_slots.release()


def temp_dir() -> Path:
    path = Path(settings.temp_dir)
    path.mkdir(parents=True, exist_ok=True)
    return path


def assert_disk_headroom(expected_size: int) -> None:
    """Refuse an upload that the staging directory cannot hold.

    Checks both the configured budget and the filesystem's actual free space —
    the second matters because the budget is a policy, not a guarantee.
    """
    staging = temp_dir()

    in_use = sum(f.stat().st_size for f in staging.glob("upload-*") if f.is_file())
    if in_use + expected_size > settings.max_temp_dir_bytes:
        raise ServiceUnavailableError(
            "The server's upload staging area is full; retry shortly",
            code="UPLOAD_CAPACITY",
            headers={"Retry-After": "60"},
        )

    free = shutil.disk_usage(staging).free
    if expected_size and free < expected_size * 1.1:
        raise ServiceUnavailableError(
            "Not enough free disk space on the server to stage this upload",
            code="INSUFFICIENT_STORAGE",
        )


@contextmanager
def staging_file() -> Iterator[Path]:
    """A temp path that is deleted no matter how the block exits."""
    path = temp_dir() / f"upload-{uuid.uuid4().hex}"
    try:
        yield path
    finally:
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:  # pragma: no cover - cleanup must not mask errors
            log.warning("staging_cleanup_failed", path=str(path), exc_info=exc)


async def stage_stream(
    stream: AsyncIterator[bytes], path: Path, *, max_size: int
) -> StagedUpload:
    """Write an incoming byte stream to disk, hashing it on the way through.

    The hash is computed here rather than by re-reading the file afterwards: the
    bytes are already in hand, and a second full pass over 2 GB is pure waste.
    """
    digest = hashlib.sha256()
    written = 0

    with path.open("wb") as handle:
        async for chunk in stream:
            if not chunk:
                continue
            written += len(chunk)
            if written > max_size:
                raise PayloadTooLargeError(
                    "The upload exceeds the maximum supported file size",
                    details={"limit": max_size},
                )
            digest.update(chunk)
            # Blocking write on the event loop thread: acceptable because the
            # kernel buffers it and the network read is the real bottleneck.
            handle.write(chunk)

    return StagedUpload(path=path, size=written, sha256=digest.hexdigest())


class _SeekableReader(Protocol):
    """A reader that can also be repositioned — what a slice view needs
    underneath it, and more than `ByteReader` promises."""

    def read(self, size: int = -1) -> bytes: ...

    def seek(self, offset: int, whence: int = 0) -> int: ...


class _SliceReader:
    """A bounded, read-only view over part of an open file.

    Lets Telethon upload a 19 MB segment straight out of the staged file with no
    second copy on disk and no 19 MB buffer in memory.
    """

    def __init__(self, handle: _SeekableReader, offset: int, length: int) -> None:
        self._handle = handle
        self._start = offset
        self._length = length
        self._position = 0
        handle.seek(offset)

    def read(self, size: int = -1) -> bytes:
        remaining = self._length - self._position
        if remaining <= 0:
            return b""
        want = remaining if size is None or size < 0 else min(size, remaining)
        data = self._handle.read(want)
        self._position += len(data)
        return data

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_SET:
            self._position = offset
        elif whence == os.SEEK_CUR:
            self._position += offset
        else:
            self._position = self._length + offset
        self._position = max(0, min(self._position, self._length))
        self._handle.seek(self._start + self._position)
        return self._position

    def tell(self) -> int:
        return self._position

    def __len__(self) -> int:
        return self._length


def plan_chunks(size: int, chunk_size: int | None = None) -> list[tuple[int, int, int]]:
    """Split ``size`` into ``(index, offset, length)`` segments."""
    step = chunk_size or settings.telegram_chunk_size
    if size <= 0:
        return []
    return [
        (index, offset, min(step, size - offset))
        for index, offset in enumerate(range(0, size, step))
    ]


async def upload_whole(
    staged: StagedUpload,
    *,
    filename: str,
    mime_type: str,
    credentials: StorageCredentials,
) -> tuple[int, str | None, str | None]:
    """Send a staged file as one Telegram message. Returns the message reference."""
    provider = get_provider()
    with staged.path.open("rb") as handle:
        result = await provider.upload(
            handle,
            UploadMetadata(filename=filename, size=staged.size, mime_type=mime_type),
            credentials,
        )
    return result.message_id, result.file_id, result.file_unique_id


async def upload_chunked(
    session: AsyncSession,
    file: File,
    staged: StagedUpload,
    credentials: StorageCredentials,
) -> list[FileChunk]:
    """Segment a staged file, upload every segment, and write the manifest.

    Segments go up one at a time on purpose. Telegram rate-limits a bot hard, and
    parallel uploads on one bot token trade a modest speed-up for `FLOOD_WAIT`
    responses that stall the whole file.
    """
    provider = get_provider(file.storage_provider)
    segments = plan_chunks(staged.size)
    uploaded: list[FileChunk] = []
    sent_message_ids: list[int] = []

    try:
        with staged.path.open("rb") as handle:
            for index, offset, length in segments:
                result = await _upload_one_chunk(
                    provider,
                    _SliceReader(handle, offset, length),
                    filename=f"{file.name}.part{index:04d}",
                    size=length,
                    mime_type="application/octet-stream",
                    credentials=credentials,
                )
                sent_message_ids.append(result.message_id)
                uploaded.append(
                    FileChunk(
                        file_id=file.id,
                        chunk_index=index,
                        size=length,
                        offset=offset,
                        telegram_message_id=result.message_id,
                        telegram_file_id=result.file_id,
                        telegram_file_unique_id=result.file_unique_id,
                    )
                )
                log.info(
                    "chunk_uploaded",
                    file_id=str(file.id),
                    index=index,
                    of=len(segments),
                )
    except Exception:
        # Roll back the remote side so a retry does not accumulate orphaned
        # messages in the user's channel.
        await _delete_orphans(provider, sent_message_ids, credentials)
        raise

    for chunk in uploaded:
        session.add(chunk)

    file.is_chunked = True
    file.chunk_count = len(uploaded)
    file.telegram_message_id = uploaded[0].telegram_message_id if uploaded else None
    file.telegram_file_id = None  # a chunked file has no single Bot API file_id
    file.size = staged.size
    await session.flush()
    return uploaded


async def _upload_one_chunk(
    provider: StorageProvider,
    reader: _SliceReader,
    *,
    filename: str,
    size: int,
    mime_type: str,
    credentials: StorageCredentials,
) -> UploadResult:
    """Upload one segment, honouring Telegram's own back-off instructions."""
    last_error: Exception | None = None
    for attempt in range(1, CHUNK_UPLOAD_ATTEMPTS + 1):
        try:
            reader.seek(0)
            return await provider.upload(  # type: ignore[attr-defined]
                reader,
                UploadMetadata(filename=filename, size=size, mime_type=mime_type),
                credentials,
            )
        except TelegramFloodWaitError as exc:
            last_error = exc
            wait = int(exc.details.get("retry_after", 30))
            if attempt == CHUNK_UPLOAD_ATTEMPTS:
                break
            log.warning("chunk_flood_wait", seconds=wait, attempt=attempt)
            await asyncio.sleep(wait)
        except Exception as exc:
            last_error = exc
            if attempt == CHUNK_UPLOAD_ATTEMPTS:
                break
            backoff = 2**attempt
            log.warning(
                "chunk_upload_retry",
                attempt=attempt,
                backoff=backoff,
                error=type(exc).__name__,
            )
            await asyncio.sleep(backoff)

    assert last_error is not None
    raise last_error


async def _delete_orphans(
    provider: StorageProvider, message_ids: list[int], credentials: StorageCredentials
) -> None:
    for message_id in message_ids:
        try:
            await provider.delete(  # type: ignore[attr-defined]
                StorageRef(channel_id=credentials.channel_id, message_id=message_id),
                credentials,
            )
        except Exception as exc:  # pragma: no cover - cleanup is best-effort
            log.warning("orphan_cleanup_failed", message_id=message_id, exc_info=exc)
    if message_ids:
        log.info("partial_upload_rolled_back", chunks=len(message_ids))


async def verify_remote(file: File, credentials: StorageCredentials) -> bool:
    """Confirm Telegram still holds this file's bytes.

    Users can delete messages directly in their channel, which leaves metadata
    pointing at nothing. This is the check behind that reconciliation.
    """
    provider = get_provider(file.storage_provider)
    if file.telegram_message_id is None or file.telegram_channel_id is None:
        return False
    info = await provider.get_info(
        StorageRef(
            channel_id=file.telegram_channel_id,
            message_id=file.telegram_message_id,
            file_id=file.telegram_file_id,
        ),
        credentials,
    )
    return info.exists


def bot_api_upload_limit() -> int:
    return settings.telegram_bot_api_max_upload


__all__ = [
    "StagedUpload",
    "TelegramStorage",
    "assert_disk_headroom",
    "bot_api_upload_limit",
    "plan_chunks",
    "stage_stream",
    "staging_file",
    "upload_chunked",
    "upload_slot",
    "upload_whole",
    "verify_remote",
]
