"""Liveness and readiness."""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app import __version__
from app.core.config import settings
from app.core.db import get_session
from app.core.envelope import Envelope, ok
from app.core.errors import ServiceUnavailableError
from app.core.logging import get_logger

log = get_logger(__name__)
router = APIRouter(tags=["health"])


class HealthOut(BaseModel):
    status: Literal["ok", "degraded"]
    version: str
    environment: str
    database: bool
    redis: bool | None = None
    mtproto_configured: bool


@router.get("/health", response_model=Envelope[HealthOut], summary="Health check")
async def health(session: AsyncSession = Depends(get_session)) -> Envelope[HealthOut]:
    """Readiness probe: fails loudly if the database is unreachable.

    A 503 here is the signal an orchestrator needs to stop routing traffic, so
    the database check is not swallowed the way the optional Redis check is.
    """
    try:
        await session.execute(text("SELECT 1"))
    except Exception as exc:
        log.error("health_database_unreachable", exc_info=exc)
        raise ServiceUnavailableError(
            "The database is unreachable", details={"database": False}
        ) from exc

    redis_ok: bool | None = None
    if settings.redis_url:
        redis_ok = await _ping_redis()

    return ok(
        HealthOut(
            status="ok" if redis_ok is not False else "degraded",
            version=__version__,
            environment=settings.app_env,
            database=True,
            redis=redis_ok,
            mtproto_configured=settings.mtproto_configured,
        )
    )


async def _ping_redis() -> bool:
    # Redis is optional: it backs revocation and cross-replica rate limits, and
    # losing it degrades those rather than breaking the API.
    try:
        import redis.asyncio as redis

        client = redis.from_url(settings.redis_url or "")
        try:
            await client.ping()
            return True
        finally:
            await client.aclose()
    except Exception as exc:
        log.warning("health_redis_unreachable", exc_info=exc)
        return False
