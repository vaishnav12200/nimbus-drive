"""Async SQLAlchemy engine, session factory and the per-request unit of work."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from typing import Any, cast
from urllib.parse import urlsplit

from sqlalchemy import CursorResult, Result
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.pool import NullPool

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)

# Supabase's Supavisor and PgBouncer both multiplex many clients onto few server
# connections. In *transaction* mode a connection is handed back to the pool
# after every statement, so a prepared statement created on one request is gone —
# or worse, belongs to someone else — by the next.
TRANSACTION_POOLER_PORT = 6543
POOLER_HOST_MARKERS = ("pooler.supabase.com", "pgbouncer")


def is_transaction_pooler(url: str) -> bool:
    """True when the URL points at a transaction-mode connection pooler.

    Detected rather than configured because getting it wrong produces
    intermittent `prepared statement "__asyncpg_stmt_N__" does not exist`
    failures under load — the kind of bug that looks like data corruption and
    only shows up in production.
    """
    try:
        parts = urlsplit(url)
    except ValueError:  # pragma: no cover - malformed URL surfaces elsewhere
        return False

    host = (parts.hostname or "").lower()
    if parts.port == TRANSACTION_POOLER_PORT:
        return True
    # Session mode (5432) on the same host *does* support prepared statements,
    # so the host alone is not enough — only treat it as transaction mode when
    # the port says so.
    return any(marker in host for marker in POOLER_HOST_MARKERS) and parts.port is None


def _engine_kwargs() -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "echo": settings.db_echo,
        "pool_pre_ping": True,
        "future": True,
    }

    if settings.app_env == "test":
        # Tests create and drop the schema per session; a pool would hold stale
        # connections across those boundaries.
        kwargs["poolclass"] = NullPool
    else:
        kwargs["pool_size"] = settings.db_pool_size
        kwargs["max_overflow"] = settings.db_max_overflow

    if is_transaction_pooler(settings.database_url):
        # Three settings, because one is not enough in practice:
        #   statement_cache_size          — asyncpg's own cache
        #   prepared_statement_cache_size — SQLAlchemy's asyncpg dialect cache
        #   prepared_statement_name_func  — SQLAlchemy still emits the occasional
        #       prepared statement for server-side cursors; unique names stop two
        #       pooled sessions colliding on `__asyncpg_stmt_1__`.
        kwargs["connect_args"] = {
            "statement_cache_size": 0,
            "prepared_statement_cache_size": 0,
            "prepared_statement_name_func": lambda: f"__nimbus_{uuid.uuid4().hex}__",
        }
        # The pooler is already pooling; a second pool on top just holds its
        # scarce server-side connections open for nothing.
        kwargs.pop("pool_size", None)
        kwargs.pop("max_overflow", None)
        kwargs["poolclass"] = NullPool
        log.info("database_transaction_pooler_detected", prepared_statements="disabled")

    return kwargs


engine: AsyncEngine = create_async_engine(settings.database_url, **_engine_kwargs())

SessionFactory: async_sessionmaker[AsyncSession] = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autoflush=False,
)


async def get_session() -> AsyncIterator[AsyncSession]:
    """FastAPI dependency: one transaction per request.

    Commits when the handler returns cleanly, rolls back on any exception. Handlers
    that stream a response must finish reading from the session *before* returning,
    because dependency teardown runs before the response body is sent.
    """
    async with SessionFactory() as session:
        try:
            yield session
        except Exception:
            await session.rollback()
            raise
        else:
            await session.commit()


async def dispose_engine() -> None:
    await engine.dispose()


def rowcount(result: Result[Any]) -> int:
    """Rows affected by a DML statement.

    ``AsyncSession.execute`` is typed as returning ``Result``, but an
    INSERT/UPDATE/DELETE always produces a ``CursorResult`` — which is where
    ``rowcount`` actually lives. The cast keeps that fact in one place instead of
    scattering ``# type: ignore`` across every service.
    """
    return int(cast("CursorResult[Any]", result).rowcount or 0)
