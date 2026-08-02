"""Share links: creation, the public surface, expiry and quotas."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient

from tests.conftest import file_payload


async def make_file(
    client: AsyncClient, headers: dict[str, str], **overrides: Any
) -> dict[str, Any]:
    response = await client.post(
        "/api/files", headers=headers, json=file_payload(**overrides)
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def make_share(
    client: AsyncClient, headers: dict[str, str], file_id: str, **options: Any
) -> dict[str, Any]:
    response = await client.post(
        "/api/shares", headers=headers, json={"file_id": file_id, **options}
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def test_create_and_read_a_public_link(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await make_file(client, headers)
    share = await make_share(client, headers, file["id"])

    assert len(share["token"]) >= 40  # ≥32 bytes of entropy, base64url encoded

    public = await client.get(f"/api/shares/{share['token']}")
    assert public.status_code == 200
    data = public.json()["data"]
    assert data["name"] == "report.pdf"
    assert data["requires_password"] is False
    assert data["downloads_remaining"] is None


async def test_the_public_view_leaks_nothing_about_the_owner(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await make_file(client, headers)
    share = await make_share(client, headers, file["id"])

    body = (await client.get(f"/api/shares/{share['token']}")).json()["data"]
    for leaked in ("user_id", "folder_id", "telegram_message_id", "telegram_channel_id"):
        assert leaked not in body


async def test_encrypted_files_cannot_be_shared(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    """The recipient would have no key, so the link would produce garbage."""
    headers = bound_user["headers"]
    # Encryption must be enabled before a file may be flagged encrypted —
    # otherwise no salt is stored and the file could never be decrypted at all.
    await client.post("/api/encryption", json={"kdf": "argon2id"}, headers=headers)
    file = await make_file(client, headers, is_encrypted=True)

    response = await client.post(
        "/api/shares", headers=headers, json={"file_id": file["id"]}
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "CANNOT_SHARE_ENCRYPTED"


async def test_trashed_files_cannot_be_shared(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await make_file(client, headers)
    await client.delete(f"/api/files/{file['id']}", headers=headers)

    response = await client.post(
        "/api/shares", headers=headers, json={"file_id": file["id"]}
    )
    assert response.status_code == 404


async def test_a_revoked_link_reads_as_not_found(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await make_file(client, headers)
    share = await make_share(client, headers, file["id"])

    await client.delete(f"/api/shares/{share['id']}", headers=headers)

    public = await client.get(f"/api/shares/{share['token']}")
    assert public.status_code == 404
    assert public.json()["error"]["code"] == "SHARE_NOT_FOUND"


async def test_an_expired_link_is_gone(
    client: AsyncClient, bound_user: dict[str, Any], session: Any
) -> None:
    from datetime import UTC, datetime, timedelta

    from sqlalchemy import select

    from app.models import SharedLink

    headers = bound_user["headers"]
    file = await make_file(client, headers)
    share = await make_share(client, headers, file["id"], expires_in=3600)

    # Wind the clock back rather than sleeping an hour.
    row = (
        await session.execute(
            select(SharedLink).where(SharedLink.token == share["token"])
        )
    ).scalar_one()
    row.expires_at = datetime.now(UTC) - timedelta(minutes=1)
    await session.commit()

    public = await client.get(f"/api/shares/{share['token']}")
    assert public.status_code == 410
    assert public.json()["error"]["code"] == "SHARE_EXPIRED"


async def test_a_password_protected_link_advertises_the_requirement(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await make_file(client, headers)
    share = await make_share(client, headers, file["id"], password="open-sesame")

    public = await client.get(f"/api/shares/{share['token']}")
    assert public.json()["data"]["requires_password"] is True


async def test_download_without_the_password_is_refused(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await make_file(client, headers)
    share = await make_share(client, headers, file["id"], password="open-sesame")

    response = await client.get(f"/api/shares/{share['token']}/download")
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "SHARE_PASSWORD_REQUIRED"

    wrong = await client.get(
        f"/api/shares/{share['token']}/download",
        headers={"X-Share-Password": "not-it"},
    )
    assert wrong.status_code == 403
    assert wrong.json()["error"]["code"] == "SHARE_PASSWORD_INVALID"


async def test_unknown_tokens_are_not_found(client: AsyncClient) -> None:
    response = await client.get("/api/shares/definitely-not-a-real-token")
    assert response.status_code == 404


async def test_download_quota_is_reported_and_enforced(
    client: AsyncClient, bound_user: dict[str, Any], session: Any
) -> None:
    from sqlalchemy import select

    from app.models import SharedLink

    headers = bound_user["headers"]
    file = await make_file(client, headers)
    share = await make_share(client, headers, file["id"], max_downloads=2)

    public = await client.get(f"/api/shares/{share['token']}")
    assert public.json()["data"]["downloads_remaining"] == 2

    # Simulate the quota being spent without reaching Telegram for the bytes.
    row = (
        await session.execute(
            select(SharedLink).where(SharedLink.token == share["token"])
        )
    ).scalar_one()
    row.download_count = 2
    await session.commit()

    exhausted = await client.get(f"/api/shares/{share['token']}")
    assert exhausted.status_code == 410
    assert exhausted.json()["error"]["code"] == "SHARE_EXPIRED"


async def test_owner_can_list_their_links(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    headers = bound_user["headers"]
    file = await make_file(client, headers)
    await make_share(client, headers, file["id"])

    response = await client.get("/api/shares", headers=headers)
    rows = response.json()["data"]
    assert len(rows) == 1
    assert rows[0]["file_name"] == "report.pdf"


async def test_listing_shares_requires_authentication(client: AsyncClient) -> None:
    assert (await client.get("/api/shares")).status_code == 401
