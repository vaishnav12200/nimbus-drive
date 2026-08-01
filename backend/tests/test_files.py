"""File metadata: creation, trash lifecycle, copy/move, dedup."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient

from tests.conftest import TEST_CHANNEL_ID, file_payload


async def create_file(
    client: AsyncClient, headers: dict[str, str], **overrides: Any
) -> dict[str, Any]:
    response = await client.post(
        "/api/files", headers=headers, json=file_payload(**overrides)
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def test_creating_metadata_requires_a_bound_channel(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    response = await client.post("/api/files", headers=headers, json=file_payload())
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "TELEGRAM_NOT_CONFIGURED"


async def test_channel_id_comes_from_the_binding_not_the_client(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """A client must not be able to claim its file lives in another channel."""
    file = await create_file(
        client,
        bound_user["headers"],
        telegram_channel_id=-1009999999999,  # ignored: not part of the schema
    )
    assert file["telegram_channel_id"] == TEST_CHANNEL_ID


async def test_oversized_client_upload_is_redirected_to_the_backend_path(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.post(
        "/api/files",
        headers=bound_user["headers"],
        json=file_payload(size=25 * 1024 * 1024),
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "USE_BACKEND_UPLOAD"


async def test_list_paginates_with_meta(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    for index in range(5):
        await create_file(
            client, headers, name=f"file-{index}.txt", telegram_message_id=index + 1
        )

    response = await client.get("/api/files?limit=2&page=1", headers=headers)
    body = response.json()
    assert len(body["data"]) == 2
    assert body["meta"] == {"page": 1, "limit": 2, "total": 5, "pages": 3}


async def test_soft_delete_then_restore(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await create_file(client, headers)

    await client.delete(f"/api/files/{file['id']}", headers=headers)

    listed = await client.get("/api/files", headers=headers)
    assert listed.json()["data"] == []

    trashed = await client.get("/api/files?trash=true", headers=headers)
    assert len(trashed.json()["data"]) == 1
    assert trashed.json()["data"][0]["deleted_at"] is not None

    restored = await client.post(f"/api/files/{file['id']}/restore", headers=headers)
    assert restored.status_code == 200
    assert restored.json()["data"]["is_deleted"] is False

    back = await client.get("/api/files", headers=headers)
    assert len(back.json()["data"]) == 1


async def test_rename_move_and_favourite(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await create_file(client, headers)
    folder = (
        await client.post("/api/folders", headers=headers, json={"name": "Target"})
    ).json()["data"]

    response = await client.patch(
        f"/api/files/{file['id']}",
        headers=headers,
        json={"name": "renamed.pdf", "folder_id": folder["id"], "is_favorite": True},
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["name"] == "renamed.pdf"
    assert data["folder_id"] == folder["id"]
    assert data["is_favorite"] is True

    favourites = await client.get("/api/files?favorites=true", headers=headers)
    assert len(favourites.json()["data"]) == 1


async def test_moving_to_a_null_folder_returns_the_file_to_the_root(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    folder = (
        await client.post("/api/folders", headers=headers, json={"name": "Somewhere"})
    ).json()["data"]
    file = await create_file(client, headers, folder_id=folder["id"])

    response = await client.patch(
        f"/api/files/{file['id']}", headers=headers, json={"folder_id": None}
    )
    assert response.json()["data"]["folder_id"] is None


async def test_tags_are_normalised_and_replaced(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await create_file(client, headers, tags=["Work", "  INVOICE ", "work"])
    assert file["tags"] == ["invoice", "work"]

    updated = await client.patch(
        f"/api/files/{file['id']}", headers=headers, json={"tags": ["archive"]}
    )
    assert updated.json()["data"]["tags"] == ["archive"]


async def test_copy_shares_the_telegram_message(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """A copy is a second name for the same bytes, not a second upload."""
    headers = bound_user["headers"]
    file = await create_file(client, headers)

    response = await client.post(
        f"/api/files/{file['id']}/copy", headers=headers, json={}
    )
    assert response.status_code == 200
    copy = response.json()["data"]

    assert copy["id"] != file["id"]
    assert copy["name"] == "report (copy).pdf"
    assert copy["telegram_message_id"] == file["telegram_message_id"]


async def test_deleting_one_copy_leaves_the_other_intact(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await create_file(client, headers)
    copy = (
        await client.post(f"/api/files/{file['id']}/copy", headers=headers, json={})
    ).json()["data"]

    # Permanent delete would remove the Telegram message if this were the last
    # reference; the copy must keep it alive.
    deleted = await client.delete(
        f"/api/files/{file['id']}?permanent=true", headers=headers
    )
    assert deleted.status_code == 200

    survivor = await client.get(f"/api/files/{copy['id']}", headers=headers)
    assert survivor.status_code == 200
    assert survivor.json()["data"]["telegram_message_id"] == file["telegram_message_id"]


async def test_move_endpoint_validates_the_target_folder(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await create_file(client, headers)
    foreign_folder = (
        await client.post(
            "/api/folders", headers=other_bound_user["headers"], json={"name": "Theirs"}
        )
    ).json()["data"]

    response = await client.post(
        f"/api/files/{file['id']}/move",
        headers=headers,
        json={"target_folder_id": foreign_folder["id"]},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FOLDER_NOT_FOUND"


async def test_dedup_finds_a_previous_upload(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    digest = "b" * 64
    await create_file(client, headers, sha256=digest, name="original.bin")

    response = await client.get(f"/api/files/dedup?sha256={digest}", headers=headers)
    assert response.json()["data"]["found"] is True
    assert response.json()["data"]["name"] == "original.bin"


async def test_dedup_misses_for_an_unknown_hash(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.get(
        f"/api/files/dedup?sha256={'c' * 64}", headers=bound_user["headers"]
    )
    assert response.json()["data"] == {
        "found": False,
        "file_id": None,
        "name": None,
        "size": None,
    }


async def test_emptying_the_trash_removes_rows_permanently(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await create_file(client, headers)
    await client.delete(f"/api/files/{file['id']}", headers=headers)

    response = await client.post("/api/files/trash/empty", headers=headers)
    assert response.status_code == 200

    assert (
        await client.get(f"/api/files/{file['id']}", headers=headers)
    ).status_code == 404
    assert (await client.get("/api/files?trash=true", headers=headers)).json()[
        "data"
    ] == []


async def test_reserve_creates_a_row_with_no_bytes_yet(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.post(
        "/api/files/reserve",
        headers=bound_user["headers"],
        json={"name": "movie.mp4", "size": 100 * 1024 * 1024, "mime_type": "video/mp4"},
    )
    assert response.status_code == 201
    data = response.json()["data"]
    assert data["telegram_message_id"] is None
    assert data["is_chunked"] is False


async def test_reserve_rejects_files_over_telegrams_own_ceiling(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.post(
        "/api/files/reserve",
        headers=bound_user["headers"],
        json={"name": "huge.bin", "size": 3 * 1024 * 1024 * 1024},
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "FILE_TOO_LARGE"


async def test_downloading_a_file_with_no_bytes_fails_clearly(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    reserved = (
        await client.post(
            "/api/files/reserve",
            headers=bound_user["headers"],
            json={"name": "pending.bin", "size": 1024},
        )
    ).json()["data"]

    response = await client.get(
        f"/api/files/{reserved['id']}/download", headers=bound_user["headers"]
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "FILE_NOT_UPLOADED"
