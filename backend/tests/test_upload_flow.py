"""The large-file path end to end, through the real HTTP endpoints.

Telegram is swapped for an in-memory provider registered under the name
`telegram`, so this exercises the actual staging, hashing, chunking, manifest
writing, reassembly and Range handling — everything except the network call.

The size thresholds are shrunk to a few hundred bytes so a chunked upload is
cheap to test; the code paths are identical to the 19 MB ones.
"""

from __future__ import annotations

import hashlib
import os
from typing import Any

import pytest
from httpx import AsyncClient

from app.core.config import settings
from tests.test_chunking import FakeStorage

BOT_API_LIMIT = 256
CHUNK_SIZE = 128


@pytest.fixture
def telegram_stub(monkeypatch: pytest.MonkeyPatch) -> FakeStorage:
    """Register an in-memory provider under Telegram's name and shrink the
    size thresholds so chunking happens at a testable scale."""
    from app.providers import registry

    storage = FakeStorage()
    storage.name = "telegram"

    original = registry._REGISTRY.get("telegram")
    registry.register_provider(storage)

    monkeypatch.setattr(settings, "telegram_bot_api_max_upload", BOT_API_LIMIT)
    monkeypatch.setattr(settings, "telegram_chunk_size", CHUNK_SIZE)

    yield storage

    if original is not None:
        registry.register_provider(original)


async def _reserve(
    client: AsyncClient, headers: dict[str, str], **body: Any
) -> dict[str, Any]:
    response = await client.post("/api/files/reserve", headers=headers, json=body)
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def test_small_upload_through_the_backend_is_one_message(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    headers = bound_user["headers"]
    payload = os.urandom(100)

    reserved = await _reserve(client, headers, name="small.bin", size=len(payload))
    response = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )
    assert response.status_code == 200, response.text

    data = response.json()["data"]
    assert data["is_chunked"] is False
    assert data["chunk_count"] == 0
    assert data["telegram_message_id"] is not None
    assert data["sha256"] == hashlib.sha256(payload).hexdigest()


async def test_large_upload_is_chunked_with_a_correct_manifest(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    headers = bound_user["headers"]
    payload = os.urandom(500)  # 4 chunks: 128 + 128 + 128 + 116

    reserved = await _reserve(client, headers, name="big.bin", size=len(payload))
    response = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )
    assert response.status_code == 200, response.text

    data = response.json()["data"]
    assert data["is_chunked"] is True
    assert data["chunk_count"] == 4

    chunks = sorted(data["chunks"], key=lambda c: c["chunk_index"])
    assert [c["size"] for c in chunks] == [128, 128, 128, 116]
    assert [c["offset"] for c in chunks] == [0, 128, 256, 384]
    assert sum(c["size"] for c in chunks) == len(payload)

    # Every chunk is a distinct Telegram message.
    assert len({c["telegram_message_id"] for c in chunks}) == 4


async def test_chunked_download_reassembles_the_original_bytes(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    """The definition of done for Phase 4: the SHA-256 survives the round trip."""
    headers = bound_user["headers"]
    payload = os.urandom(500)
    digest = hashlib.sha256(payload).hexdigest()

    reserved = await _reserve(client, headers, name="movie.mp4", size=len(payload))
    await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )

    download = await client.get(f"/api/files/{reserved['id']}/download", headers=headers)
    assert download.status_code == 200
    assert download.headers["accept-ranges"] == "bytes"
    assert hashlib.sha256(download.content).hexdigest() == digest


async def test_a_range_request_returns_206_with_the_right_slice(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    """Seeking in a player: the byte offset must map onto the right chunk."""
    headers = bound_user["headers"]
    payload = os.urandom(500)

    reserved = await _reserve(client, headers, name="clip.mp4", size=len(payload))
    await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )

    # A window deliberately straddling a chunk boundary at byte 128.
    response = await client.get(
        f"/api/files/{reserved['id']}/stream",
        headers={**headers, "Range": "bytes=100-200"},
    )
    assert response.status_code == 206
    assert response.headers["content-range"] == "bytes 100-200/500"
    assert response.content == payload[100:201]


async def test_multipart_upload_is_accepted_too(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    headers = bound_user["headers"]
    payload = os.urandom(300)

    reserved = await _reserve(client, headers, name="form.bin", size=len(payload))
    response = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers=headers,
        files={"file": ("form.bin", payload, "application/octet-stream")},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["is_chunked"] is True


async def test_a_truncated_body_is_rejected_not_recorded(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    """Recording a short upload as successful would leave metadata describing
    bytes that do not exist."""
    headers = bound_user["headers"]
    reserved = await _reserve(client, headers, name="short.bin", size=500)

    response = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=os.urandom(100),
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "SIZE_MISMATCH"

    still_empty = await client.get(f"/api/files/{reserved['id']}", headers=headers)
    assert still_empty.json()["data"]["telegram_message_id"] is None


async def test_a_checksum_mismatch_is_rejected(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    headers = bound_user["headers"]
    payload = os.urandom(200)
    reserved = await _reserve(
        client, headers, name="claimed.bin", size=len(payload), sha256="d" * 64
    )

    response = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "CHECKSUM_MISMATCH"


async def test_an_empty_body_is_rejected(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    headers = bound_user["headers"]
    reserved = await _reserve(client, headers, name="nothing.bin", size=10)

    response = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=b"",
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "EMPTY_UPLOAD"


async def test_uploading_twice_to_the_same_row_is_a_conflict(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    headers = bound_user["headers"]
    payload = os.urandom(100)
    reserved = await _reserve(client, headers, name="once.bin", size=len(payload))

    first = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )
    assert first.status_code == 200

    second = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )
    assert second.status_code == 409
    assert second.json()["error"]["code"] == "ALREADY_UPLOADED"


async def test_the_staging_directory_is_left_clean(
    client: AsyncClient, bound_user: dict[str, Any], telegram_stub: FakeStorage
) -> None:
    """Cross-cutting rule 2: no file bytes survive the request, on any path."""
    from pathlib import Path

    headers = bound_user["headers"]
    staging = Path(settings.temp_dir)

    reserved = await _reserve(client, headers, name="ok.bin", size=300)
    await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=os.urandom(300),
    )

    failed = await _reserve(client, headers, name="bad.bin", size=300)
    await client.post(
        f"/api/files/{failed['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=os.urandom(50),
    )

    assert list(staging.glob("upload-*")) == []


async def test_a_transient_chunk_failure_is_retried(
    client: AsyncClient,
    bound_user: dict[str, Any],
    telegram_stub: FakeStorage,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """One flaky chunk must not fail a 500 MB upload."""
    from app.services import uploads as upload_service

    monkeypatch.setattr(upload_service, "CHUNK_UPLOAD_ATTEMPTS", 2)
    monkeypatch.setattr(upload_service.asyncio, "sleep", _no_sleep)

    headers = bound_user["headers"]
    original_upload = telegram_stub.upload
    calls = {"n": 0}

    async def flaky_upload(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        if calls["n"] == 3:  # fails once, then the retry goes through
            raise RuntimeError("Telegram hiccup")
        return await original_upload(*args, **kwargs)

    telegram_stub.upload = flaky_upload  # type: ignore[method-assign]

    payload = os.urandom(500)
    reserved = await _reserve(client, headers, name="flaky.bin", size=len(payload))
    response = await client.post(
        f"/api/files/{reserved['id']}/upload",
        headers={**headers, "Content-Type": "application/octet-stream"},
        content=payload,
    )
    assert response.status_code == 200
    assert response.json()["data"]["chunk_count"] == 4


async def _no_sleep(_seconds: float) -> None:
    """Collapse retry back-off so tests do not wait it out."""
    return None


async def test_a_failed_chunk_upload_removes_the_messages_already_sent(
    client: AsyncClient,
    bound_user: dict[str, Any],
    telegram_stub: FakeStorage,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A retry must not accumulate orphaned junk in the user's channel."""
    from app.services import uploads as upload_service

    monkeypatch.setattr(upload_service, "CHUNK_UPLOAD_ATTEMPTS", 1)

    headers = bound_user["headers"]
    original_upload = telegram_stub.upload
    calls = {"n": 0}

    async def failing_upload(*args: Any, **kwargs: Any) -> Any:
        calls["n"] += 1
        # Permanent failure from the third chunk on, so retries cannot rescue it.
        if calls["n"] >= 3:
            raise RuntimeError("Telegram fell over mid-upload")
        return await original_upload(*args, **kwargs)

    telegram_stub.upload = failing_upload  # type: ignore[method-assign]

    reserved = await _reserve(client, headers, name="doomed.bin", size=500)

    # ASGITransport re-raises unhandled application exceptions rather than
    # rendering the 500 a real client would see; the failure itself is not the
    # point of this test, the cleanup after it is.
    with pytest.raises(RuntimeError, match="fell over"):
        await client.post(
            f"/api/files/{reserved['id']}/upload",
            headers={**headers, "Content-Type": "application/octet-stream"},
            content=os.urandom(500),
        )

    # The two chunks that did land were deleted again — a retry must not
    # accumulate orphaned messages in the user's channel.
    assert len(telegram_stub.deleted) == 2
    assert telegram_stub.blobs == {}

    # And the metadata row still shows no stored bytes.
    row = await client.get(f"/api/files/{reserved['id']}", headers=headers)
    assert row.json()["data"]["is_chunked"] is False
    assert row.json()["data"]["chunk_count"] == 0
