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


def test_supabase_session_pooler_string_is_rewritten() -> None:
    """The exact string Supabase's dashboard hands out for a persistent server."""
    assert _url(
        "postgresql://postgres.abcdefgh:pw@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
    ) == (
        "postgresql+asyncpg://postgres.abcdefgh:pw"
        "@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
    )


class TestTransactionPoolerDetection:
    """Getting this wrong surfaces as intermittent `prepared statement
    "__asyncpg_stmt_N__" does not exist` errors under concurrency — never in
    development, only in production."""

    def test_supabase_transaction_pooler_is_detected(self) -> None:
        from app.core.db import is_transaction_pooler

        assert is_transaction_pooler(
            "postgresql+asyncpg://postgres.ref:pw"
            "@aws-0-us-east-1.pooler.supabase.com:6543/postgres"
        )

    def test_supabase_session_pooler_is_not_transaction_mode(self) -> None:
        """Session mode shares the hostname but *does* support prepared
        statements — disabling them there would be a needless slowdown."""
        from app.core.db import is_transaction_pooler

        assert not is_transaction_pooler(
            "postgresql+asyncpg://postgres.ref:pw"
            "@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
        )

    def test_supabase_direct_connection_is_not_pooled(self) -> None:
        from app.core.db import is_transaction_pooler

        assert not is_transaction_pooler(
            "postgresql+asyncpg://postgres:pw@db.abcdefgh.supabase.co:5432/postgres"
        )

    def test_plain_postgres_is_not_pooled(self) -> None:
        from app.core.db import is_transaction_pooler

        assert not is_transaction_pooler(
            "postgresql+asyncpg://nimbus:nimbus@localhost:5432/nimbus"
        )

    def test_any_host_on_6543_is_treated_as_a_transaction_pooler(self) -> None:
        """PgBouncer's conventional port. Assuming the safe configuration for an
        unknown pooler beats discovering it under load."""
        from app.core.db import is_transaction_pooler

        assert is_transaction_pooler("postgresql+asyncpg://u:p@pgbouncer.internal:6543/db")


class TestCorsOriginsFromEnvironment:
    """These must go through `monkeypatch.setenv`, not the constructor.

    pydantic-settings decodes complex types with `json.loads` *inside the
    settings source*, before any field validator runs — a path the constructor
    skips entirely. An earlier version of this test passed a string to
    `Settings(...)` directly, so it stayed green while `CORS_ORIGINS=*` crashed
    the container on boot with a JSONDecodeError.
    """

    def test_wildcard(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CORS_ORIGINS", "*")
        assert Settings().cors_origins == ["*"]

    def test_single_origin(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CORS_ORIGINS", "https://app.example")
        assert Settings().cors_origins == ["https://app.example"]

    def test_comma_separated(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CORS_ORIGINS", "https://a.example, https://b.example")
        assert Settings().cors_origins == ["https://a.example", "https://b.example"]

    def test_json_array_still_works(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CORS_ORIGINS", '["https://a.example","https://b.example"]')
        assert Settings().cors_origins == ["https://a.example", "https://b.example"]

    def test_empty_value(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CORS_ORIGINS", "")
        assert Settings().cors_origins == []

    def test_malformed_json_gives_a_readable_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("CORS_ORIGINS", '["unclosed')
        with pytest.raises(ValueError, match="comma-separated"):
            Settings()


def test_every_env_var_in_the_deploy_template_loads(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Boot Settings from exactly the variables the Render template sets.

    The CORS bug got through because each setting was checked in isolation and
    none of it was ever loaded the way production loads it.
    """
    env = {
        "APP_ENV": "production",
        "DATABASE_URL": "postgresql://u:p@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres",
        "DB_POOL_SIZE": "5",
        "DB_MAX_OVERFLOW": "5",
        "SECRET_ENCRYPTION_KEY": "bmltYnVzLWRyaXZlLXRlc3Qta2V5LTMyLWJ5dGVzISE=",
        "JWT_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----",
        "JWT_PUBLIC_KEY": "-----BEGIN PUBLIC KEY-----\\nx\\n-----END PUBLIC KEY-----",
        "CORS_ORIGINS": "*",
        "TEMP_DIR": "/var/lib/nimbus/tmp",
        "MAX_CONCURRENT_LARGE_UPLOADS": "2",
        "MAX_TEMP_DIR_BYTES": "2147483648",
        "PORT": "10000",
    }
    for key, value in env.items():
        monkeypatch.setenv(key, value)

    settings = Settings()

    assert settings.is_production
    assert settings.database_url.startswith("postgresql+asyncpg://")
    assert settings.cors_origins == ["*"]
    assert settings.db_pool_size + settings.db_max_overflow == 10
    assert settings.port == 10000
    assert settings.temp_dir == "/var/lib/nimbus/tmp"
    assert "\n" in (settings.jwt_private_key or "")


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
