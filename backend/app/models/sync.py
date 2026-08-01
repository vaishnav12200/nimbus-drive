"""Deletion tombstones for delta sync."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UUIDMixin


class SyncTombstone(UUIDMixin, Base):
    """A record that something was hard-deleted, so clients can converge.

    Files use ``is_deleted`` and stay queryable, so they need no tombstone until
    they are purged. **Folders are hard-deleted**, which leaves a client that was
    offline during the delete with no way to learn the folder is gone — the row
    simply stops appearing, and "absent from a delta" is indistinguishable from
    "unchanged".

    Rows are swept once they are older than any plausible offline period; a client
    that has been away longer than that must do a full resync rather than a delta.
    """

    __tablename__ = "sync_tombstones"
    __table_args__ = (
        Index("ix_sync_tombstones_user_id_deleted_at", "user_id", "deleted_at"),
        Index("ix_sync_tombstones_entity_id", "entity_id"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    entity_type: Mapped[str] = mapped_column(String(16), nullable=False)  # file|folder
    entity_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    deleted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )


TOMBSTONE_RETENTION_DAYS = 90
