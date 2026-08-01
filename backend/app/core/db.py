"""Async SQLAlchemy engine, session factory and the per-request unit of work."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any, cast

from sqlalchemy import CursorResult, Result
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.pool import NullPool

from app.core.config import settings


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
