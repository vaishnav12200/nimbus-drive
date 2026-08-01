"""Audit-trail writes.

Logging an action must never be the reason a user's operation fails, so every
write here is best-effort and swallows its own errors after reporting them.
"""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import get_logger
from app.models import ActivityAction, ActivityLog

log = get_logger(__name__)


async def record(
    session: AsyncSession,
    *,
    action: ActivityAction,
    user_id: uuid.UUID | None = None,
    file_id: uuid.UUID | None = None,
    ip_address: str | None = None,
    user_agent: str | None = None,
    details: dict[str, Any] | None = None,
) -> None:
    """Append one activity row to the current transaction.

    ``details`` is stored verbatim as JSONB — pass identifiers and counts, never
    credentials, file contents, or bot tokens.
    """
    try:
        session.add(
            ActivityLog(
                user_id=user_id,
                file_id=file_id,
                action=action.value,
                ip_address=ip_address,
                user_agent=(user_agent or None) and user_agent[:512],
                details=details,
            )
        )
        await session.flush()
    except Exception as exc:  # pragma: no cover - audit must not break the request
        log.warning("activity_log_write_failed", action=action.value, exc_info=exc)
