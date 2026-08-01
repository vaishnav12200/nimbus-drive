"""Chunked storage: Range parsing, chunk-span planning, and a byte round-trip.

This is the logic most likely to be silently wrong — an off-by-one when a
requested range straddles a chunk boundary produces a corrupt file rather than an
error. The round-trip test hashes the reassembled bytes to catch exactly that.
"""

from __future__ import annotations

import hashlib
import os
from collections.abc import AsyncIterator
from typing import Any, BinaryIO

import pytest

from app.core.errors import RangeNotSatisfiableError
from app.models import File, FileChunk
from app.providers.base import (
    RemoteFileInfo,
    StorageCredentials,
    StorageProvider,
    StorageRef,
    UploadMetadata,
    UploadResult,
)
from app.services import downloads
from app.services.uploads import _SliceReader, plan_chunks

CREDENTIALS = StorageCredentials(bot_token="token", channel_id=-100123)


class FakeStorage(StorageProvider):
    """In-memory stand-in for Telegram. Stores one blob per message id."""

    name = "fake"

    def __init__(self) -> None:
        self.blobs: dict[int, bytes] = {}
        self._next_id = 1000
        self.deleted: list[int] = []

    @property
    def max_single_upload(self) -> int:
        return 2_000 * 1024 * 1024

    async def upload(
        self,
        file_stream: BinaryIO,
        metadata: UploadMetadata,
        credentials: StorageCredentials,
    ) -> UploadResult:
        data = file_stream.read()
        assert len(data) == metadata.size, "provider was handed the wrong byte count"
        self._next_id += 1
        self.blobs[self._next_id] = data
        return UploadResult(message_id=self._next_id, size=len(data))

    async def download(  # type: ignore[override]
        self,
        ref: StorageRef,
        credentials: StorageCredentials,
        *,
        offset: int = 0,
        limit: int | None = None,
    ) -> AsyncIterator[bytes]:
        blob = self.blobs[ref.message_id]
        end = len(blob) if limit is None else offset + limit
        # Yield in small pieces so the caller's reassembly is exercised, not
        # short-circuited by a single convenient chunk.
        window = blob[offset:end]
        for start in range(0, len(window), 7):
            yield window[start : start + 7]

    async def delete(self, ref: StorageRef, credentials: StorageCredentials) -> None:
        self.deleted.append(ref.message_id)
        self.blobs.pop(ref.message_id, None)

    async def get_info(
        self, ref: StorageRef, credentials: StorageCredentials
    ) -> RemoteFileInfo:
        blob = self.blobs.get(ref.message_id)
        return RemoteFileInfo(size=len(blob or b""), exists=blob is not None)


@pytest.fixture
def fake_storage() -> AsyncIterator[FakeStorage]:
    from app.providers import registry

    storage = FakeStorage()
    registry.register_provider(storage)
    yield storage


# --- plan_chunks -------------------------------------------------------


def test_plan_chunks_covers_the_file_exactly() -> None:
    size, step = 50, 19
    segments = plan_chunks(size, step)

    assert [s[0] for s in segments] == [0, 1, 2]
    assert sum(s[2] for s in segments) == size
    assert segments[-1] == (2, 38, 12)  # the tail is short, not padded

    # Segments must tile the range with no gaps and no overlaps.
    cursor = 0
    for _, offset, length in segments:
        assert offset == cursor
        cursor += length


def test_plan_chunks_handles_an_exact_multiple() -> None:
    segments = plan_chunks(38, 19)
    assert len(segments) == 2
    assert segments[-1] == (1, 19, 19)


def test_plan_chunks_of_an_empty_file_is_empty() -> None:
    assert plan_chunks(0) == []


# --- _SliceReader ------------------------------------------------------


def test_slice_reader_cannot_read_past_its_window(tmp_path: Any) -> None:
    path = tmp_path / "blob"
    path.write_bytes(bytes(range(256)))

    with path.open("rb") as handle:
        reader = _SliceReader(handle, offset=10, length=5)
        assert reader.read() == bytes(range(10, 15))
        assert reader.read() == b""

        reader.seek(0)
        assert reader.read(3) == bytes(range(10, 13))
        assert reader.read(100) == bytes(range(13, 15))


# --- Range parsing -----------------------------------------------------


@pytest.mark.parametrize(
    ("header", "size", "expected"),
    [
        (None, 100, (0, 99, False)),
        ("bytes=0-49", 100, (0, 49, True)),
        ("bytes=50-", 100, (50, 99, True)),
        ("bytes=-20", 100, (80, 99, True)),
        ("bytes=0-999", 100, (0, 99, True)),  # clamped to the entity
        ("bytes=0-0", 100, (0, 0, True)),  # a single byte is a valid range
        ("not a range", 100, (0, 99, False)),  # ignored, per RFC 9110
        ("bytes=0-10,20-30", 100, (0, 99, False)),  # multi-range: serve it whole
    ],
)
def test_parse_range(
    header: str | None, size: int, expected: tuple[int, int, bool]
) -> None:
    result = downloads.parse_range(header, size, window=size)
    assert (result.start, result.end, result.partial) == expected


def test_open_ended_range_is_capped_by_the_streaming_window() -> None:
    """`bytes=0-` from a media player must not pull the whole file."""
    result = downloads.parse_range("bytes=0-", 100_000_000, window=1024)
    assert result.start == 0
    assert result.end == 1023


@pytest.mark.parametrize("header", ["bytes=500-", "bytes=200-300", "bytes=-0"])
def test_unsatisfiable_ranges_are_rejected(header: str) -> None:
    with pytest.raises(RangeNotSatisfiableError):
        downloads.parse_range(header, 100)


# --- Chunk-span planning -----------------------------------------------


def _chunked_file(chunk_sizes: list[int]) -> File:
    file = File(
        name="movie.mp4",
        original_name="movie.mp4",
        size=sum(chunk_sizes),
        mime_type="video/mp4",
        is_chunked=True,
        chunk_count=len(chunk_sizes),
        telegram_channel_id=-100123,
        storage_provider="fake",
    )
    offset = 0
    file.chunks = []
    for index, size in enumerate(chunk_sizes):
        file.chunks.append(
            FileChunk(
                chunk_index=index,
                size=size,
                offset=offset,
                telegram_message_id=1000 + index,
            )
        )
        offset += size
    return file


def test_a_range_inside_one_chunk_touches_only_that_chunk() -> None:
    file = _chunked_file([100, 100, 100])
    plan = downloads.build_plan(file, downloads.parse_range("bytes=120-150", 300))

    assert len(plan.chunks) == 1
    assert plan.chunks[0].message_id == 1001
    assert plan.chunks[0].offset_in_chunk == 20
    assert plan.chunks[0].length == 31


def test_a_range_spanning_chunks_is_split_correctly() -> None:
    """The boundary case: the read must resume at offset 0 of the next chunk."""
    file = _chunked_file([100, 100, 100])
    plan = downloads.build_plan(file, downloads.parse_range("bytes=90-210", 300))

    assert [(c.message_id, c.offset_in_chunk, c.length) for c in plan.chunks] == [
        (1000, 90, 10),
        (1001, 0, 100),
        (1002, 0, 11),
    ]
    assert sum(c.length for c in plan.chunks) == 121


def test_a_full_range_covers_every_chunk() -> None:
    file = _chunked_file([100, 100, 37])
    plan = downloads.build_plan(file, downloads.parse_range(None, 237))
    assert sum(c.length for c in plan.chunks) == 237
    assert len(plan.chunks) == 3


def test_content_range_header_reports_the_whole_entity_size() -> None:
    file = _chunked_file([100, 100])
    plan = downloads.build_plan(file, downloads.parse_range("bytes=50-99", 200))
    assert downloads.content_range_header(plan) == "bytes 50-99/200"


# --- Round trip --------------------------------------------------------


async def test_chunked_upload_and_download_preserves_the_bytes(
    fake_storage: FakeStorage,
) -> None:
    """The definition of done for large files: SHA-256 in equals SHA-256 out."""
    payload = os.urandom(1000)
    digest = hashlib.sha256(payload).hexdigest()

    chunk_size = 128
    file = _chunked_file([])
    file.chunks = []
    offset = 0
    for index, (_, start, length) in enumerate(plan_chunks(len(payload), chunk_size)):
        result = await fake_storage.upload(
            _InMemory(payload[start : start + length]),
            UploadMetadata(filename=f"part{index}", size=length),
            CREDENTIALS,
        )
        file.chunks.append(
            FileChunk(
                chunk_index=index,
                size=length,
                offset=offset,
                telegram_message_id=result.message_id,
            )
        )
        offset += length

    file.size = len(payload)
    file.is_chunked = True
    file.chunk_count = len(file.chunks)

    plan = downloads.build_plan(file, downloads.parse_range(None, file.size))
    reassembled = b"".join([chunk async for chunk in downloads.stream(plan, CREDENTIALS)])

    assert len(reassembled) == len(payload)
    assert hashlib.sha256(reassembled).hexdigest() == digest


@pytest.mark.parametrize(("start", "end"), [(0, 0), (127, 128), (500, 999), (999, 999)])
async def test_arbitrary_ranges_return_the_right_slice(
    fake_storage: FakeStorage, start: int, end: int
) -> None:
    payload = os.urandom(1000)

    file = _chunked_file([])
    file.chunks = []
    offset = 0
    for index, (_, chunk_start, length) in enumerate(plan_chunks(len(payload), 128)):
        result = await fake_storage.upload(
            _InMemory(payload[chunk_start : chunk_start + length]),
            UploadMetadata(filename=f"part{index}", size=length),
            CREDENTIALS,
        )
        file.chunks.append(
            FileChunk(
                chunk_index=index,
                size=length,
                offset=offset,
                telegram_message_id=result.message_id,
            )
        )
        offset += length
    file.size = len(payload)
    file.is_chunked = True
    file.chunk_count = len(file.chunks)

    byte_range = downloads.parse_range(f"bytes={start}-{end}", file.size)
    plan = downloads.build_plan(file, byte_range)
    got = b"".join([chunk async for chunk in downloads.stream(plan, CREDENTIALS)])

    assert got == payload[start : end + 1]


class _InMemory:
    """Minimal binary reader over a bytes object."""

    def __init__(self, data: bytes) -> None:
        self._data = data
        self._position = 0

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            chunk, self._position = self._data[self._position :], len(self._data)
            return chunk
        chunk = self._data[self._position : self._position + size]
        self._position += len(chunk)
        return chunk


def test_content_disposition_survives_non_ascii_names() -> None:
    header = downloads.content_disposition("réunion été.pdf")
    assert header.startswith("attachment; ")
    assert "filename*=UTF-8''r%C3%A9union%20%C3%A9t%C3%A9.pdf" in header


def test_inline_disposition_is_used_for_streaming() -> None:
    assert downloads.content_disposition("clip.mp4", inline=True).startswith("inline;")
