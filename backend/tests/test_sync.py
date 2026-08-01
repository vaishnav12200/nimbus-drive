"""Delta sync: boundaries, tombstones and keyset pagination."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient

from app.services.sync import OVERLAP_SECONDS, Cursor
from tests.conftest import file_payload


async def _sync(
    client: AsyncClient, headers: dict[str, str], **params: Any
) -> dict[str, Any]:
    response = await client.get("/api/sync", headers=headers, params=params)
    assert response.status_code == 200, response.text
    return response.json()["data"]


async def test_full_sync_returns_everything_as_new(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await client.post("/api/folders", headers=headers, json={"name": "Docs"})
    await client.post("/api/files", headers=headers, json=file_payload())

    delta = await _sync(client, headers)
    assert len(delta["new_files"]) == 1
    assert len(delta["new_folders"]) == 1
    assert delta["updated_files"] == []
    assert delta["deleted_files"] == []


async def test_next_since_lags_server_time_to_close_the_boundary(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """A row committed mid-request must not fall through the crack.

    `next_since` is deliberately behind `server_time`, so the following delta
    re-covers the window that was in flight.
    """
    delta = await _sync(client, bound_user["headers"])
    server_time = datetime.fromisoformat(delta["server_time"])
    next_since = datetime.fromisoformat(delta["next_since"])

    assert server_time - next_since == timedelta(seconds=OVERLAP_SECONDS)


async def test_only_changes_after_since_are_returned(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await client.post("/api/files", headers=headers, json=file_payload(name="first.pdf"))

    checkpoint = (await _sync(client, headers))["server_time"]

    await client.post(
        "/api/files",
        headers=headers,
        json=file_payload(name="second.pdf", telegram_message_id=99),
    )

    delta = await _sync(client, headers, since=checkpoint)
    assert [f["name"] for f in delta["new_files"]] == ["second.pdf"]


async def test_an_edit_lands_in_updated_not_new(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    created = (
        await client.post("/api/files", headers=headers, json=file_payload())
    ).json()["data"]

    checkpoint = (await _sync(client, headers))["server_time"]

    await client.patch(
        f"/api/files/{created['id']}", headers=headers, json={"name": "renamed.pdf"}
    )

    delta = await _sync(client, headers, since=checkpoint)
    assert delta["new_files"] == []
    assert [f["name"] for f in delta["updated_files"]] == ["renamed.pdf"]


async def test_soft_deleted_files_appear_in_deleted_files(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """Clients cannot converge on "it stopped appearing" — the delete has to be
    reported explicitly."""
    headers = bound_user["headers"]
    created = (
        await client.post("/api/files", headers=headers, json=file_payload())
    ).json()["data"]

    checkpoint = (await _sync(client, headers))["server_time"]
    await client.delete(f"/api/files/{created['id']}", headers=headers)

    delta = await _sync(client, headers, since=checkpoint)
    assert delta["deleted_files"] == [created["id"]]
    assert delta["updated_files"] == []


async def test_hard_deleted_folders_are_reported_via_tombstones(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """Folders are hard-deleted, so their absence carries no information.

    Without a tombstone an offline client would keep the folder forever.
    """
    headers = bound_user["headers"]
    folder = (
        await client.post("/api/folders", headers=headers, json={"name": "Temporary"})
    ).json()["data"]

    checkpoint = (await _sync(client, headers))["server_time"]
    await client.delete(f"/api/folders/{folder['id']}", headers=headers)

    delta = await _sync(client, headers, since=checkpoint)
    assert delta["deleted_folders"] == [folder["id"]]


async def test_purged_files_are_reported_via_tombstones(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    created = (
        await client.post("/api/files", headers=headers, json=file_payload())
    ).json()["data"]

    checkpoint = (await _sync(client, headers))["server_time"]
    await client.delete(f"/api/files/{created['id']}?permanent=true", headers=headers)

    delta = await _sync(client, headers, since=checkpoint)
    assert created["id"] in delta["deleted_files"]


async def test_cascade_folder_delete_reports_the_whole_subtree(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    parent = (
        await client.post("/api/folders", headers=headers, json={"name": "Parent"})
    ).json()["data"]
    child = (
        await client.post(
            "/api/folders",
            headers=headers,
            json={"name": "Child", "parent_id": parent["id"]},
        )
    ).json()["data"]

    checkpoint = (await _sync(client, headers))["server_time"]
    await client.delete(f"/api/folders/{parent['id']}?cascade=true", headers=headers)

    delta = await _sync(client, headers, since=checkpoint)
    assert set(delta["deleted_folders"]) == {parent["id"], child["id"]}


async def test_pagination_uses_a_keyset_cursor(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """Bulk writes share an `updated_at`, so paginating on the timestamp alone
    would skip rows or loop. The cursor carries `(updated_at, id)`."""
    headers = bound_user["headers"]
    for index in range(6):
        await client.post(
            "/api/files",
            headers=headers,
            json=file_payload(name=f"f{index}.bin", telegram_message_id=index + 1),
        )

    seen: set[str] = set()
    delta = await _sync(client, headers, limit=2)
    seen.update(f["id"] for f in delta["new_files"])

    guard = 0
    while delta["has_more"] and guard < 10:
        guard += 1
        delta = await _sync(client, headers, limit=2, cursor=delta["next_cursor"])
        seen.update(f["id"] for f in delta["new_files"])

    assert len(seen) == 6


async def test_a_malformed_cursor_is_rejected_clearly(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.get(
        "/api/sync", headers=bound_user["headers"], params={"cursor": "!!!not-base64!!!"}
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_CURSOR"


async def test_a_stale_client_is_told_to_resync_from_scratch(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """Past the tombstone retention window a delta cannot be trusted, because
    the record of what was deleted is gone."""
    ancient = (datetime.now(UTC) - timedelta(days=400)).isoformat()
    delta = await _sync(client, bound_user["headers"], since=ancient)
    assert delta["full_resync_required"] is True


async def test_since_accepts_a_unix_timestamp(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    epoch = str((datetime.now(UTC) - timedelta(minutes=5)).timestamp())
    response = await client.get(
        "/api/sync", headers=bound_user["headers"], params={"since": epoch}
    )
    assert response.status_code == 200


async def test_an_unparseable_since_is_rejected(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.get(
        "/api/sync", headers=bound_user["headers"], params={"since": "yesterday"}
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_SINCE"


def test_cursor_round_trips() -> None:
    import uuid

    original = Cursor(updated_at=datetime.now(UTC), entity_id=uuid.uuid4())
    assert Cursor.decode(original.encode()) == original


async def test_snapshot_counts_live_rows(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    await client.post("/api/folders", headers=headers, json={"name": "One"})
    created = (
        await client.post("/api/files", headers=headers, json=file_payload())
    ).json()["data"]
    await client.delete(f"/api/files/{created['id']}", headers=headers)

    response = await client.get("/api/sync/snapshot", headers=headers)
    data = response.json()["data"]
    assert data["file_count"] == 0  # trashed files do not count
    assert data["folder_count"] == 1
