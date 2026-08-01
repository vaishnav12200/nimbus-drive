"""Download and Range-aware streaming.

A chunked file is N independent Telegram messages, but HTTP callers see one
contiguous byte range. Translating between the two is what this module does:
given ``bytes=A-B`` it works out which chunks the range touches and what offset
within each to start at, then concatenates the pieces.

Everything here operates on plain dataclasses, never on ORM objects or a live
session. FastAPI tears a request's dependencies down *before* the streaming body
is consumed, so touching the session inside the generator would raise on a closed
connection.
"""

from __future__ import annotations

import re
from collections.abc import AsyncIterator
from dataclasses import dataclass

from app.core.errors import RangeNotSatisfiableError
from app.core.logging import get_logger
from app.models import File
from app.providers import get_provider
from app.providers.base import StorageCredentials, StorageRef

log = get_logger(__name__)

RANGE_PATTERN = re.compile(r"^bytes=(\d*)-(\d*)$")

# Cap on how much a single open-ended Range request will serve. Media players ask
# for `bytes=0-` and then close the connection once buffered; without a cap the
# server keeps pulling the whole file from Telegram for a client that stopped
# listening.
DEFAULT_STREAM_WINDOW = 8 * 1024 * 1024


@dataclass(frozen=True)
class ChunkPlan:
    """One chunk's contribution to a byte range."""

    message_id: int
    file_id: str | None
    offset_in_chunk: int
    length: int


@dataclass(frozen=True)
class StreamPlan:
    """Everything needed to serve a byte range, detached from the ORM."""

    channel_id: int
    storage_provider: str
    total_size: int
    start: int
    end: int  # inclusive
    chunks: list[ChunkPlan]
    whole_ref: StorageRef | None

    @property
    def length(self) -> int:
        return self.end - self.start + 1


@dataclass(frozen=True)
class ByteRange:
    start: int
    end: int  # inclusive
    partial: bool

    @property
    def length(self) -> int:
        return self.end - self.start + 1


def parse_range(header: str | None, size: int, *, window: int | None = None) -> ByteRange:
    """Interpret an HTTP Range header (RFC 9110 §14).

    Only a single range is supported; multipart/byteranges buys nothing for media
    playback and doubles the response-assembly complexity. A multi-range request
    is served as the full entity, which is explicitly allowed.
    """
    if size <= 0:
        return ByteRange(start=0, end=0, partial=False)

    if not header:
        return ByteRange(start=0, end=size - 1, partial=False)

    match = RANGE_PATTERN.match(header.strip())
    if match is None:
        # Unsatisfiable syntax, or a multi-range request: fall back to the whole
        # entity rather than erroring, per the spec's "ignore invalid Range".
        return ByteRange(start=0, end=size - 1, partial=False)

    raw_start, raw_end = match.group(1), match.group(2)

    if not raw_start and not raw_end:
        return ByteRange(start=0, end=size - 1, partial=False)

    if not raw_start:
        # "bytes=-500" — the final 500 bytes.
        suffix = int(raw_end)
        if suffix == 0:
            raise RangeNotSatisfiableError(details={"size": size})
        start = max(0, size - suffix)
        end = size - 1
    else:
        start = int(raw_start)
        end = int(raw_end) if raw_end else size - 1

    if start >= size or start > end:
        raise RangeNotSatisfiableError(
            "The requested range lies outside the file",
            details={"size": size, "start": start},
        )

    end = min(end, size - 1)

    # Bound an open-ended request so a player that buffers and disconnects does
    # not cost us a full-file pull from Telegram.
    if not raw_end:
        end = min(end, start + (window or DEFAULT_STREAM_WINDOW) - 1)

    return ByteRange(start=start, end=end, partial=True)


def build_plan(file: File, byte_range: ByteRange) -> StreamPlan:
    """Resolve a byte range against a file's storage layout.

    Must be called while the session is still open — it reads ``file.chunks``.
    """
    if file.telegram_channel_id is None:
        raise RangeNotSatisfiableError("This file has no stored bytes")

    if not file.is_chunked:
        return StreamPlan(
            channel_id=file.telegram_channel_id,
            storage_provider=file.storage_provider,
            total_size=file.size,
            start=byte_range.start,
            end=byte_range.end,
            chunks=[],
            whole_ref=StorageRef(
                channel_id=file.telegram_channel_id,
                message_id=file.telegram_message_id or 0,
                file_id=file.telegram_file_id,
                file_unique_id=file.telegram_file_unique_id,
            ),
        )

    plans: list[ChunkPlan] = []
    for chunk in sorted(file.chunks, key=lambda c: c.chunk_index):
        chunk_start = chunk.offset
        chunk_end = chunk.offset + chunk.size - 1

        # Skip chunks entirely outside the requested window.
        if chunk_end < byte_range.start or chunk_start > byte_range.end:
            continue

        read_from = max(byte_range.start, chunk_start) - chunk_start
        read_to = min(byte_range.end, chunk_end) - chunk_start
        plans.append(
            ChunkPlan(
                message_id=chunk.telegram_message_id,
                file_id=chunk.telegram_file_id,
                offset_in_chunk=read_from,
                length=read_to - read_from + 1,
            )
        )

    if not plans:
        raise RangeNotSatisfiableError(
            "No stored chunk covers the requested range",
            details={"size": file.size},
        )

    return StreamPlan(
        channel_id=file.telegram_channel_id,
        storage_provider=file.storage_provider,
        total_size=file.size,
        start=byte_range.start,
        end=byte_range.end,
        chunks=plans,
        whole_ref=None,
    )


async def stream(
    plan: StreamPlan, credentials: StorageCredentials
) -> AsyncIterator[bytes]:
    """Yield exactly the bytes the plan describes, in order."""
    provider = get_provider(plan.storage_provider)

    if plan.whole_ref is not None:
        async for piece in provider.download(
            plan.whole_ref,
            credentials,
            offset=plan.start,
            limit=plan.length,
        ):
            yield piece
        return

    for chunk in plan.chunks:
        ref = StorageRef(
            channel_id=plan.channel_id,
            message_id=chunk.message_id,
            file_id=chunk.file_id,
        )
        async for piece in provider.download(
            ref, credentials, offset=chunk.offset_in_chunk, limit=chunk.length
        ):
            yield piece


def content_range_header(plan: StreamPlan) -> str:
    return f"bytes {plan.start}-{plan.end}/{plan.total_size}"


def content_disposition(filename: str, *, inline: bool = False) -> str:
    """RFC 6266 disposition that survives non-ASCII names.

    The plain `filename` is a mangled ASCII fallback for old clients; `filename*`
    carries the real UTF-8 name for everyone else.
    """
    from urllib.parse import quote

    ascii_name = filename.encode("ascii", "replace").decode("ascii").replace('"', "'")
    disposition = "inline" if inline else "attachment"
    return (
        f'{disposition}; filename="{ascii_name}"; '
        f"filename*=UTF-8''{quote(filename, safe='')}"
    )
