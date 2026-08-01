"""Cross-tenant isolation (cross-cutting rule 1).

An id in a URL is never sufficient authorisation. Every one of these asserts that
a resource belonging to someone else reads as 404 — not 403, which would confirm
the id exists.
"""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient

from tests.conftest import file_payload


async def _their_file(client: AsyncClient, owner: dict[str, Any]) -> dict[str, Any]:
    response = await client.post(
        "/api/files", headers=owner["headers"], json=file_payload()
    )
    assert response.status_code == 201
    return response.json()["data"]


async def _their_folder(client: AsyncClient, owner: dict[str, Any]) -> dict[str, Any]:
    response = await client.post(
        "/api/folders", headers=owner["headers"], json={"name": "Private"}
    )
    return response.json()["data"]


async def test_cannot_read_another_users_file(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    file = await _their_file(client, other_bound_user)
    response = await client.get(f"/api/files/{file['id']}", headers=bound_user["headers"])
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FILE_NOT_FOUND"


async def test_cannot_modify_another_users_file(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    file = await _their_file(client, other_bound_user)
    response = await client.patch(
        f"/api/files/{file['id']}",
        headers=bound_user["headers"],
        json={"name": "mine.pdf"},
    )
    assert response.status_code == 404

    # And the real owner still sees the original name.
    original = await client.get(
        f"/api/files/{file['id']}", headers=other_bound_user["headers"]
    )
    assert original.json()["data"]["name"] == "report.pdf"


async def test_cannot_delete_another_users_file(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    file = await _their_file(client, other_bound_user)
    assert (
        await client.delete(f"/api/files/{file['id']}", headers=bound_user["headers"])
    ).status_code == 404
    assert (
        await client.get(f"/api/files/{file['id']}", headers=other_bound_user["headers"])
    ).status_code == 200


async def test_cannot_download_or_stream_another_users_file(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    file = await _their_file(client, other_bound_user)
    for suffix in ("download", "stream", "ticket"):
        response = await client.get(
            f"/api/files/{file['id']}/{suffix}", headers=bound_user["headers"]
        )
        assert response.status_code == 404, suffix


async def test_cannot_copy_another_users_file(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    file = await _their_file(client, other_bound_user)
    response = await client.post(
        f"/api/files/{file['id']}/copy", headers=bound_user["headers"], json={}
    )
    assert response.status_code == 404


async def test_cannot_read_or_delete_another_users_folder(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    folder = await _their_folder(client, other_bound_user)
    assert (
        await client.get(f"/api/folders/{folder['id']}", headers=bound_user["headers"])
    ).status_code == 404
    assert (
        await client.delete(f"/api/folders/{folder['id']}", headers=bound_user["headers"])
    ).status_code == 404


async def test_listings_never_leak_across_accounts(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    await _their_file(client, other_bound_user)
    await _their_folder(client, other_bound_user)

    assert (await client.get("/api/files", headers=bound_user["headers"])).json()[
        "data"
    ] == []
    assert (await client.get("/api/folders", headers=bound_user["headers"])).json()[
        "data"
    ] == []
    assert (
        await client.get("/api/search?q=report", headers=bound_user["headers"])
    ).json()["data"] == []


async def test_sync_never_leaks_across_accounts(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    await _their_file(client, other_bound_user)
    response = await client.get("/api/sync", headers=bound_user["headers"])
    assert response.json()["data"]["new_files"] == []


async def test_cannot_revoke_another_users_share(
    client: AsyncClient, bound_user: dict[str, Any], other_bound_user: dict[str, Any]
) -> None:
    file = await _their_file(client, other_bound_user)
    share = (
        await client.post(
            "/api/shares",
            headers=other_bound_user["headers"],
            json={"file_id": file["id"]},
        )
    ).json()["data"]

    response = await client.delete(
        f"/api/shares/{share['id']}", headers=bound_user["headers"]
    )
    assert response.status_code == 404

    # Still live for its actual owner.
    public = await client.get(f"/api/shares/{share['token']}")
    assert public.status_code == 200


async def test_cannot_read_another_users_telegram_config(
    client: AsyncClient, bound_user: dict[str, Any], headers: dict[str, str]
) -> None:
    """A second account has no binding of its own and must not inherit one."""
    from tests.conftest import register_user

    stranger = await register_user(client)
    response = await client.get(
        "/api/telegram/config",
        headers={"Authorization": f"Bearer {stranger['access_token']}"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "TELEGRAM_NOT_CONFIGURED"
