"""Auth: registration, login, and the rotating refresh-token lifecycle."""

from __future__ import annotations

from typing import Any

import pytest
from httpx import AsyncClient

from tests.conftest import auth_headers, register_user


async def test_register_returns_a_token_pair(client: AsyncClient) -> None:
    response = await client.post(
        "/api/auth/register",
        json={"email": "New.User@Example.com", "password": "hunter2hunter2"},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["success"] is True
    assert body["data"]["token_type"] == "bearer"
    assert body["data"]["expires_in"] > 0
    assert body["data"]["access_token"]
    assert body["data"]["refresh_token"]


async def test_email_is_normalised_and_unique(client: AsyncClient) -> None:
    await register_user(client, email="Case.Test@Example.com")
    duplicate = await client.post(
        "/api/auth/register",
        json={"email": "case.test@example.com", "password": "hunter2hunter2"},
    )
    assert duplicate.status_code == 409
    assert duplicate.json()["error"]["code"] == "EMAIL_ALREADY_REGISTERED"


async def test_login_then_call_a_protected_route(client: AsyncClient) -> None:
    account = await register_user(client)

    login = await client.post(
        "/api/auth/login",
        json={"email": account["email"], "password": account["password"]},
    )
    assert login.status_code == 200

    me = await client.get("/api/auth/me", headers=auth_headers(login.json()["data"]))
    assert me.status_code == 200
    assert me.json()["data"]["email"] == account["email"].lower()
    assert me.json()["data"]["has_password"] is True


@pytest.mark.parametrize(
    ("email_suffix", "password"),
    [("", "wrong-password-entirely"), ("nope", "hunter2hunter2")],
)
async def test_bad_credentials_are_indistinguishable(
    client: AsyncClient, email_suffix: str, password: str
) -> None:
    """A wrong password and an unknown account must look identical.

    Any difference lets an attacker enumerate which addresses have accounts.
    """
    account = await register_user(client)
    response = await client.post(
        "/api/auth/login",
        json={"email": account["email"] + email_suffix, "password": password},
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "INVALID_CREDENTIALS"


async def test_protected_route_rejects_missing_and_garbage_tokens(
    client: AsyncClient,
) -> None:
    assert (await client.get("/api/auth/me")).status_code == 401
    bad = await client.get(
        "/api/auth/me", headers={"Authorization": "Bearer not-a-real-token"}
    )
    assert bad.status_code == 401
    assert bad.json()["error"]["code"] == "INVALID_TOKEN"


async def test_refresh_rotates_the_token(client: AsyncClient) -> None:
    account = await register_user(client)

    refreshed = await client.post(
        "/api/auth/refresh", json={"refresh_token": account["refresh_token"]}
    )
    assert refreshed.status_code == 200
    new_tokens = refreshed.json()["data"]
    assert new_tokens["refresh_token"] != account["refresh_token"]

    me = await client.get("/api/auth/me", headers=auth_headers(new_tokens))
    assert me.status_code == 200


async def test_reusing_a_rotated_token_kills_the_whole_family(
    client: AsyncClient,
) -> None:
    """Replaying a consumed refresh token revokes every descendant session.

    This is the OAuth 2.1 reuse-detection response: a replay means either theft
    or a client bug, and both are safer resolved by forcing a real re-login.
    """
    account = await register_user(client)

    first = await client.post(
        "/api/auth/refresh", json={"refresh_token": account["refresh_token"]}
    )
    rotated = first.json()["data"]

    replay = await client.post(
        "/api/auth/refresh", json={"refresh_token": account["refresh_token"]}
    )
    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "TOKEN_REUSE_DETECTED"

    # The token handed out by the legitimate refresh is collateral damage — by
    # design, since we cannot tell which party was the attacker.
    after = await client.post(
        "/api/auth/refresh", json={"refresh_token": rotated["refresh_token"]}
    )
    assert after.status_code == 401


async def test_unknown_refresh_token_is_rejected(client: AsyncClient) -> None:
    response = await client.post("/api/auth/refresh", json={"refresh_token": "x" * 64})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "INVALID_TOKEN"


async def test_logout_revokes_the_refresh_token(
    client: AsyncClient, user_tokens: dict[str, Any]
) -> None:
    logout = await client.post(
        "/api/auth/logout",
        headers=auth_headers(user_tokens),
        json={"refresh_token": user_tokens["refresh_token"]},
    )
    assert logout.status_code == 200

    replay = await client.post(
        "/api/auth/refresh", json={"refresh_token": user_tokens["refresh_token"]}
    )
    assert replay.status_code == 401


async def test_logout_all_revokes_every_session(
    client: AsyncClient, user_tokens: dict[str, Any]
) -> None:
    account = user_tokens
    second = await client.post(
        "/api/auth/login",
        json={"email": account["email"], "password": account["password"]},
    )
    second_tokens = second.json()["data"]

    await client.post("/api/auth/logout-all", headers=auth_headers(account))

    for token in (account["refresh_token"], second_tokens["refresh_token"]):
        replay = await client.post("/api/auth/refresh", json={"refresh_token": token})
        assert replay.status_code == 401


async def test_sessions_lists_only_live_sessions(
    client: AsyncClient, user_tokens: dict[str, Any]
) -> None:
    response = await client.get("/api/auth/sessions", headers=auth_headers(user_tokens))
    assert response.status_code == 200
    assert len(response.json()["data"]) == 1

    await client.post(
        "/api/auth/refresh", json={"refresh_token": user_tokens["refresh_token"]}
    )

    # The rotated token is no longer usable, so it drops out of the list.
    after = await client.get("/api/auth/sessions", headers=auth_headers(user_tokens))
    assert len(after.json()["data"]) == 1


async def test_short_password_is_rejected_with_field_detail(
    client: AsyncClient,
) -> None:
    response = await client.post(
        "/api/auth/register", json={"email": "a@example.com", "password": "short"}
    )
    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "VALIDATION_ERROR"
    assert error["details"]["fields"][0]["field"] == "password"


async def test_login_is_rate_limited_per_account(client: AsyncClient) -> None:
    """Repeated failures must stop being free before they become useful."""
    account = await register_user(client)

    statuses = []
    for _ in range(12):
        response = await client.post(
            "/api/auth/login",
            json={"email": account["email"], "password": "definitely-wrong"},
        )
        statuses.append(response.status_code)

    assert 429 in statuses
    limited = next(s for s in statuses if s == 429)
    assert limited == 429
