"""Append-only audit trail."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import DateTime, ForeignKey, Index, String, text
from sqlalchemy.dialects.postgresql import INET, JSONB
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class ActivityLog(UUIDMixin, Base):
    """One audited action.

    ``file_id`` is SET NULL rather than CASCADE so purging a file does not erase
    the record that it was purged. ``details`` carries action-specific context and
    must never receive credentials or file contents.
    """

    __tablename__ = "activity_logs"
    __table_args__ = (
        Index("ix_activity_logs_user_id_created_at", "user_id", "created_at"),
        Index("ix_activity_logs_file_id", "file_id"),
    )

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    file_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("files.id", ondelete="SET NULL")
    )

    action: Mapped[str] = mapped_column(String(32), nullable=False)
    ip_address: Mapped[str | None] = mapped_column(INET)
    user_agent: Mapped[str | None] = mapped_column(String(512))
    details: Mapped[dict[str, Any] | None] = mapped_column(JSONB)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<ActivityLog {self.action} user={self.user_id}>"
