"""Settings parsing — mostly the connection strings hosting providers hand out."""

from __future__ import annotations

import pytest

from app.core.config import Settings


def _url(value: str) -> str:
    return Settings(database_url=value).database_url


@pytest.mark.parametrize(
    ("supplied", "expected"),
    [
        # What Render's `fromDatabase` injects.
        (
            "postgresql://nimbus:pw@dpg-abc-a.oregon-postgres.render.com/nimbus",
            "postgresql+asyncpg://nimbus:pw@dpg-abc-a.oregon-postgres.render.com/nimbus",
        ),
        # Heroku-style legacy scheme.
        (
            "postgres://user:pw@host:5432/db",
            "postgresql+asyncpg://user:pw@host:5432/db",
        ),
        # Already explicit — left alone.
        (
            "postgresql+asyncpg://user:pw@host:5432/db",
            "postgresql+asyncpg://user:pw@host:5432/db",
        ),
    ],
)
def test_provider_connection_strings_are_rewritten_for_asyncpg(
    supplied: str, expected: str
) -> None:
    """Without this the app would load the synchronous psycopg2 driver and fail
    at the first query — the single most likely deploy-time failure."""
    assert _url(supplied) == expected


def test_an_explicit_driver_choice_is_respected() -> None:
    assert _url("postgresql+psycopg://u:p@h/d") == "postgresql+psycopg://u:p@h/d"


@pytest.mark.parametrize(
    ("supplied", "expected_fragment"),
    [
        ("postgresql://u:p@h/d?sslmode=require", "ssl=require"),
        ("postgresql://u:p@h/d?sslmode=verify-full", "ssl=verify-full"),
        ("postgresql://u:p@h/d?sslmode=disable", "ssl=disable"),
    ],
)
def test_libpq_sslmode_is_translated_for_asyncpg(
    supplied: str, expected_fragment: str
) -> None:
    """`sslmode` is a libpq parameter; asyncpg rejects it outright. Render's
    *external* connection string carries it."""
    result = _url(supplied)
    assert expected_fragment in result
    assert "sslmode" not in result


def test_a_non_postgres_url_is_left_alone() -> None:
    assert _url("sqlite+aiosqlite:///./local.db") == "sqlite+aiosqlite:///./local.db"


def test_cors_origins_accept_a_comma_separated_string() -> None:
    """Env vars are strings; a list-typed setting has to cope with that."""
    settings = Settings(cors_origins="https://a.example, https://b.example")
    assert settings.cors_origins == ["https://a.example", "https://b.example"]


def test_production_refuses_to_boot_without_secrets() -> None:
    """Failing at startup beats signing tokens with a dev key in production."""
    with pytest.raises(ValueError, match="Missing required production settings"):
        Settings(app_env="production", jwt_private_key=None, jwt_public_key=None)


def test_production_boots_when_secrets_are_present() -> None:
    settings = Settings(
        app_env="production",
        jwt_private_key="-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----",
        jwt_public_key="-----BEGIN PUBLIC KEY-----\nx\n-----END PUBLIC KEY-----",
        secret_encryption_key="bmltYnVzLWRyaXZlLXRlc3Qta2V5LTMyLWJ5dGVzISE=",
    )
    assert settings.is_production


def test_pem_keys_survive_being_passed_as_one_line() -> None:
    """Most secret stores are single-line; PEMs are not."""
    settings = Settings(
        jwt_public_key="-----BEGIN PUBLIC KEY-----\\nabc\\n-----END PUBLIC KEY-----"
    )
    assert "\n" in (settings.jwt_public_key or "")
    assert "\\n" not in (settings.jwt_public_key or "")


def test_encryption_key_must_be_32_bytes() -> None:
    import base64

    with pytest.raises(ValueError, match="32 bytes"):
        Settings(secret_encryption_key=base64.b64encode(b"too-short").decode())


def test_encryption_key_must_be_base64() -> None:
    with pytest.raises(ValueError, match="base64"):
        Settings(secret_encryption_key="not base64 at all!!")
