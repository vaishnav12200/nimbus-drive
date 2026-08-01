"""Application settings, loaded from the environment (see `.env.example`)."""

from __future__ import annotations

import base64
import functools
from typing import Literal

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

MB = 1024 * 1024


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # --- Application ---
    app_env: Literal["development", "test", "production"] = "development"
    debug: bool = False
    api_prefix: str = "/api"
    project_name: str = "Nimbus Drive"
    cors_origins: list[str] = Field(default_factory=lambda: ["*"])

    # --- Database ---
    database_url: str = "postgresql+asyncpg://nimbus:nimbus@localhost:5432/nimbus"
    db_pool_size: int = 10
    db_max_overflow: int = 20
    db_echo: bool = False

    # --- Server ---
    # Render injects PORT (default 10000) and requires the process to bind it.
    port: int = 8000
    host: str = "0.0.0.0"

    # --- Redis (optional: token revocation + rate limits) ---
    redis_url: str | None = None

    # --- JWT (RS256, per spec §9.1) ---
    jwt_private_key: str | None = None  # PEM, PKCS#8. Newlines may be written as \n.
    jwt_public_key: str | None = None  # PEM, SubjectPublicKeyInfo.
    jwt_algorithm: Literal["RS256"] = "RS256"
    jwt_issuer: str = "nimbus-drive"
    access_token_ttl_minutes: int = 15
    refresh_token_ttl_days: int = 7

    # --- Secret encryption (bot tokens at rest, AES-256-GCM) ---
    # base64-encoded 32 raw bytes: `openssl rand -base64 32`
    secret_encryption_key: str | None = None

    # --- Password hashing (Argon2id) ---
    argon2_time_cost: int = 3
    argon2_memory_cost: int = 65536  # KiB
    argon2_parallelism: int = 4

    # --- Telegram ---
    telegram_api_id: int | None = None  # my.telegram.org, needed for MTProto
    telegram_api_hash: str | None = None
    telegram_bot_api_base: str = "https://api.telegram.org"
    telegram_bot_api_max_upload: int = 20 * MB  # hard Bot API limit
    telegram_max_file_size: int = 2000 * MB  # Telegram's per-file cap
    telegram_chunk_size: int = 19 * MB  # segment size for chunked uploads
    telegram_request_timeout: float = 120.0

    # --- Large-file staging ---
    temp_dir: str = "/tmp/nimbus"
    max_concurrent_large_uploads: int = 3
    max_temp_dir_bytes: int = 10 * 1024 * MB  # refuse new uploads past this

    # --- OAuth ---
    google_client_id: str | None = None
    github_client_id: str | None = None
    github_client_secret: str | None = None

    # --- Behaviour ---
    trash_retention_days: int = 30
    default_page_size: int = 50
    max_page_size: int = 200

    # --- Rate limits ("<count>/<seconds>") ---
    rate_limit_login: str = "10/300"
    rate_limit_register: str = "5/3600"
    rate_limit_share_public: str = "60/60"

    @field_validator("database_url", mode="before")
    @classmethod
    def _normalize_database_url(cls, v: object) -> object:
        """Accept the connection strings hosting providers actually hand out.

        Render's `fromDatabase` (and Heroku, and most managed Postgres) supplies
        `postgresql://…`, which SQLAlchemy maps to psycopg2 — a *synchronous*
        driver this app cannot use. Rewriting the scheme here means the platform's
        value can be wired straight through with no manual editing, which is the
        difference between a one-click blueprint and a deploy-time footgun.

        `sslmode` is also translated: it is a libpq parameter that asyncpg does
        not understand and would reject outright.
        """
        if not isinstance(v, str) or not v:
            return v

        scheme, separator, rest = v.partition("://")
        if not separator:
            return v

        if scheme in {"postgres", "postgresql"}:
            v = f"postgresql+asyncpg://{rest}"
        elif scheme.startswith(("postgres+", "postgresql+")):
            return v  # an explicit driver was chosen; respect it

        if "sslmode=" in v:
            # libpq's `sslmode=require` is asyncpg's `ssl=require`; the weaker
            # modes have no asyncpg equivalent and are dropped to `prefer`.
            for libpq, asyncpg in (
                ("sslmode=require", "ssl=require"),
                ("sslmode=verify-full", "ssl=verify-full"),
                ("sslmode=verify-ca", "ssl=verify-full"),
                ("sslmode=prefer", "ssl=prefer"),
                ("sslmode=allow", "ssl=prefer"),
                ("sslmode=disable", "ssl=disable"),
            ):
                v = v.replace(libpq, asyncpg)
        return v

    @field_validator("jwt_private_key", "jwt_public_key", mode="before")
    @classmethod
    def _unescape_pem(cls, v: object) -> object:
        """Allow PEM keys to be supplied as single-line env vars with literal \\n."""
        if isinstance(v, str) and "\\n" in v:
            return v.replace("\\n", "\n")
        return v

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _split_origins(cls, v: object) -> object:
        if isinstance(v, str) and not v.startswith("["):
            return [o.strip() for o in v.split(",") if o.strip()]
        return v

    @field_validator("secret_encryption_key")
    @classmethod
    def _validate_secret_key(cls, v: str | None) -> str | None:
        if v is None:
            return v
        try:
            raw = base64.b64decode(v, validate=True)
        except Exception as exc:  # pragma: no cover - config error path
            raise ValueError("SECRET_ENCRYPTION_KEY must be valid base64") from exc
        if len(raw) != 32:
            raise ValueError("SECRET_ENCRYPTION_KEY must decode to exactly 32 bytes")
        return v

    @model_validator(mode="after")
    def _require_production_secrets(self) -> Settings:
        if self.app_env == "production":
            missing = [
                name
                for name, value in (
                    ("JWT_PRIVATE_KEY", self.jwt_private_key),
                    ("JWT_PUBLIC_KEY", self.jwt_public_key),
                    ("SECRET_ENCRYPTION_KEY", self.secret_encryption_key),
                )
                if not value
            ]
            if missing:
                raise ValueError(
                    "Missing required production settings: " + ", ".join(missing)
                )
        return self

    @property
    def is_production(self) -> bool:
        return self.app_env == "production"

    @property
    def mtproto_configured(self) -> bool:
        return self.telegram_api_id is not None and bool(self.telegram_api_hash)


@functools.lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
