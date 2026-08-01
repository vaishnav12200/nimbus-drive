"""The response envelope and error contract every client depends on."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient

from tests.conftest import file_payload


async def test_health_reports_the_database(client: AsyncClient) -> None:
    response = await client.get("/health")
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["status"] == "ok"
    assert data["database"] is True
    assert data["environment"] == "test"


async def test_success_responses_use_the_envelope(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    body = (await client.get("/api/auth/me", headers=headers)).json()
    assert body["success"] is True
    assert "data" in body
    assert "error" not in body


async def test_list_responses_carry_pagination_meta(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    body = (await client.get("/api/files", headers=bound_user["headers"])).json()
    assert set(body["meta"]) == {"page", "limit", "total", "pages"}


async def test_error_responses_use_the_error_envelope(client: AsyncClient) -> None:
    body = (await client.get("/api/auth/me")).json()
    assert body["success"] is False
    assert set(body["error"]) >= {"code", "message"}
    assert "data" not in body


async def test_unknown_routes_produce_the_same_envelope(client: AsyncClient) -> None:
    """Even Starlette's own 404 has to speak the project's error format."""
    response = await client.get("/api/does-not-exist")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


async def test_validation_errors_name_the_offending_field(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    response = await client.post(
        "/api/files",
        headers=bound_user["headers"],
        json=file_payload(size=-5),
    )
    assert response.status_code == 422
    fields = [f["field"] for f in response.json()["error"]["details"]["fields"]]
    assert "size" in fields


async def test_every_response_carries_a_request_id(client: AsyncClient) -> None:
    """The id is how a user's bug report gets tied to a log line."""
    response = await client.get("/health")
    assert response.headers.get("X-Request-ID")


async def test_an_inbound_request_id_is_preserved(client: AsyncClient) -> None:
    response = await client.get("/health", headers={"X-Request-ID": "trace-me-123"})
    assert response.headers["X-Request-ID"] == "trace-me-123"


async def test_openapi_schema_builds(client: AsyncClient) -> None:
    """A malformed response_model breaks schema generation, not the endpoint —
    so it stays invisible until someone opens /docs."""
    response = await client.get("/openapi.json")
    assert response.status_code == 200
    assert len(response.json()["paths"]) > 30


async def test_the_bot_token_is_never_returned_in_plaintext(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    from tests.conftest import TEST_BOT_TOKEN

    response = await client.get("/api/telegram/config", headers=bound_user["headers"])
    assert response.status_code == 200
    assert TEST_BOT_TOKEN not in response.text
    assert response.json()["data"]["bot_token_masked"].endswith(TEST_BOT_TOKEN[-4:])


async def test_a_positive_channel_id_is_rejected_early(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    """Pasting a user id instead of a channel id is the most common onboarding
    mistake; catching it here beats a confusing 'chat not found' later."""
    response = await client.post(
        "/api/telegram/config",
        headers=headers,
        json={
            "bot_token": "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw",
            "channel_id": 1234567890,
        },
    )
    assert response.status_code == 422


async def test_a_malformed_bot_token_is_rejected_without_a_network_call(
    client: AsyncClient, headers: dict[str, str]
) -> None:
    response = await client.post(
        "/api/telegram/config",
        headers=headers,
        json={"bot_token": "obviously-not-a-token", "channel_id": -1001234567890},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "BOT_TOKEN_MALFORMED"


async def test_page_size_is_clamped_to_the_configured_maximum(
    client: AsyncClient, bound_user: dict[str, Any]
) -> None:
    from app.core.config import settings

    response = await client.get("/api/files?limit=500", headers=bound_user["headers"])
    assert response.json()["meta"]["limit"] == settings.max_page_size
