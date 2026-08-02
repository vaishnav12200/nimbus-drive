"""Test fixtures.

Tests run against a real PostgreSQL database, not SQLite: the schema depends on
`pg_trgm`, `INET`, `JSONB`, partial indexes and `ON CONFLICT` semantics that
SQLite either lacks or fakes. Testing against a different engine than production
uses would leave exactly the interesting parts unverified.

Point `TEST_DATABASE_URL` at a throwaway database. It is created if missing and
truncated between tests.
"""

from __future__ import annotations

import os

# Must happen before anything imports app.core.config: Settings is a module-level
# singleton, so the environment has to be right at first import.
os.environ.setdefault("APP_ENV", "test")
os.environ.setdefault(
    "DATABASE_URL",
    os.environ.get(
        "TEST_DATABASE_URL",
        "postgresql+asyncpg://nimbus:nimbus@localhost:55432/nimbus_test",
    ),
)
os.environ.setdefault(
    "SECRET_ENCRYPTION_KEY", "bmltYnVzLWRyaXZlLXRlc3Qta2V5LTMyLWJ5dGVzISE="
)
os.environ.setdefault("TEMP_DIR", "/tmp/nimbus-test")
os.environ.pop("REDIS_URL", None)

import uuid
from collections.abc import AsyncIterator
from typing import Any

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.pool import NullPool

from app.core.config import settings
from app.core.db import get_session
from app.main import create_app
from app.models import Base, User, UserTelegramConfig

TEST_CHANNEL_ID = -1001234567890
TEST_BOT_TOKEN = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"


def _admin_url() -> str:
    """Same server, `postgres` database — used to CREATE DATABASE."""
    base, _, _ = settings.database_url.rpartition("/")
    return f"{base}/postgres"


def _database_name() -> str:
    return settings.database_url.rpartition("/")[2]


@pytest.fixture(scope="session")
async def _database() -> AsyncIterator[None]:
    admin = create_async_engine(_admin_url(), isolation_level="AUTOCOMMIT")
    name = _database_name()
    async with admin.connect() as conn:
        exists = await conn.scalar(
            text("SELECT 1 FROM pg_database WHERE datname = :name"), {"name": name}
        )
        if not exists:
            await conn.execute(text(f'CREATE DATABASE "{name}"'))
    await admin.dispose()

    engine = create_async_engine(settings.database_url)
    async with engine.begin() as conn:
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS pg_trgm"))

        # drop_all before create_all, because create_all only creates *missing
        # tables* — it will not add a column to a table that already exists. A
        # test database built before a model gained a column would otherwise
        # keep failing with "column does not exist" until someone dropped it by
        # hand, and only on machines that had run the suite before. Rebuilding
        # makes the schema always match the models.
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
        await conn.execute(
            text(
                "CREATE INDEX IF NOT EXISTS ix_files_name_trgm "
                "ON files USING gin (name gin_trgm_ops)"
            )
        )
    await engine.dispose()
    yield


@pytest.fixture(scope="session")
async def engine(_database: None):  # type: ignore[no-untyped-def]
    # NullPool: nothing is held between tests, so a connection can never outlive
    # the loop that created it.
    engine = create_async_engine(settings.database_url, poolclass=NullPool)
    yield engine
    await engine.dispose()


@pytest.fixture(autouse=True)
async def reset_rate_limits() -> None:
    """The limiter is a process-wide singleton; without this, tests would count
    against each other's quotas and fail in whatever order they happen to run."""
    from app.core.ratelimit import limiter

    await limiter.clear_all()


DB_FIXTURES = frozenset({"engine", "session", "app", "client"})


@pytest.fixture(autouse=True)
async def clean_tables(request: pytest.FixtureRequest) -> AsyncIterator[None]:
    """Truncate everything between tests that touch the database.

    TRUNCATE ... CASCADE is far faster than dropping and recreating the schema,
    and it resets every table in one statement so no ordering rules apply.

    Tests that ask for no database fixture are skipped entirely, so the pure
    unit suites (config parsing, Range maths, crypto, error mapping) run with no
    PostgreSQL at all — which is the difference between `pytest tests/test_config.py`
    working on a fresh clone and failing with a connection error.
    """
    if not DB_FIXTURES & set(request.fixturenames):
        yield
        return

    engine = request.getfixturevalue("engine")
    async with engine.begin() as conn:
        tables = ", ".join(f'"{t.name}"' for t in reversed(Base.metadata.sorted_tables))
        await conn.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    yield


@pytest.fixture
async def session(engine) -> AsyncIterator[AsyncSession]:  # type: ignore[no-untyped-def]
    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)
    async with factory() as session:
        yield session
        await session.commit()


@pytest.fixture
async def app(engine):  # type: ignore[no-untyped-def]
    application = create_app()

    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)

    async def override_get_session() -> AsyncIterator[AsyncSession]:
        async with factory() as session:
            try:
                yield session
            except Exception:
                await session.rollback()
                raise
            else:
                await session.commit()

    application.dependency_overrides[get_session] = override_get_session

    async with LifespanManager(application):
        yield application


@pytest.fixture
async def client(app) -> AsyncIterator[AsyncClient]:  # type: ignore[no-untyped-def]
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        yield client


# --- Account helpers ---------------------------------------------------


@pytest.fixture
def credentials() -> dict[str, str]:
    return {
        "email": f"user-{uuid.uuid4().hex[:8]}@example.com",
        "password": "hunter2hunter2",
    }


async def register_user(client: AsyncClient, **overrides: Any) -> dict[str, Any]:
    payload = {
        "email": f"user-{uuid.uuid4().hex[:8]}@example.com",
        "password": "hunter2hunter2",
        **overrides,
    }
    response = await client.post("/api/auth/register", json=payload)
    assert response.status_code == 201, response.text
    data = response.json()["data"]
    return {**payload, **data}


def auth_headers(tokens: dict[str, Any]) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


@pytest.fixture
async def user_tokens(client: AsyncClient) -> dict[str, Any]:
    return await register_user(client)


@pytest.fixture
def headers(user_tokens: dict[str, Any]) -> dict[str, str]:
    return auth_headers(user_tokens)


@pytest.fixture
async def other_tokens(client: AsyncClient) -> dict[str, Any]:
    return await register_user(client)


@pytest.fixture
def other_headers(other_tokens: dict[str, Any]) -> dict[str, str]:
    return auth_headers(other_tokens)


async def _bind_channel(session: AsyncSession, email: str) -> UserTelegramConfig:
    from sqlalchemy import select

    from app.core.crypto import encrypt

    user = (
        await session.execute(select(User).where(User.email == email.lower()))
    ).scalar_one()
    config = UserTelegramConfig(
        user_id=user.id,
        bot_token_encrypted=encrypt(
            TEST_BOT_TOKEN, aad=f"telegram-bot-token:{user.id}".encode()
        ),
        bot_token_hint=TEST_BOT_TOKEN[-4:],
        channel_id=TEST_CHANNEL_ID,
        channel_name="Test Channel",
        is_active=True,
    )
    session.add(config)
    await session.commit()
    return config


@pytest.fixture
async def bound_user(
    session: AsyncSession, user_tokens: dict[str, Any], headers: dict[str, str]
) -> dict[str, Any]:
    """A registered user with a Telegram channel already bound.

    Bound directly in the database rather than through `POST /api/telegram/config`
    so the fixture does not need to reach Telegram's `getMe`.
    """
    await _bind_channel(session, user_tokens["email"])
    return {**user_tokens, "headers": headers, "channel_id": TEST_CHANNEL_ID}


@pytest.fixture
async def other_bound_user(
    session: AsyncSession, other_tokens: dict[str, Any], other_headers: dict[str, str]
) -> dict[str, Any]:
    await _bind_channel(session, other_tokens["email"])
    return {**other_tokens, "headers": other_headers, "channel_id": TEST_CHANNEL_ID}


def file_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "name": "report.pdf",
        "size": 1024,
        "mime_type": "application/pdf",
        "telegram_message_id": 42,
        "telegram_file_id": "BQACAgEAAxkBAAI",
        "sha256": "a" * 64,
    }
    payload.update(overrides)
    return payload
