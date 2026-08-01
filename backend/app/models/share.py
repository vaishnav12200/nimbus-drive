"""Public share links."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.models.file import File
    from app.models.user import User


class SharedLink(UUIDMixin, TimestampMixin, Base):
    """An unauthenticated download grant for exactly one file.

    ``token`` is the URL-visible secret (≥ 32 bytes of CSPRNG output, base64url).
    It is indexed and unique because it is the sole lookup key on the public path.
    ``password_hash`` is optional Argon2 over a user-chosen passphrase.
    """

    __tablename__ = "shared_links"
    __table_args__ = (
        CheckConstraint(
            "max_downloads IS NULL OR max_downloads > 0", name="max_downloads_positive"
        ),
        CheckConstraint("download_count >= 0", name="download_count_non_negative"),
        Index("ix_shared_links_user_id", "user_id"),
        Index("ix_shared_links_file_id", "file_id"),
    )

    file_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("files.id", ondelete="CASCADE"), nullable=False
    )
    # Denormalised from the file so listing and revoking a user's links never
    # needs a join, and an ownership check is one predicate.
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )

    token: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    max_downloads: Mapped[int | None] = mapped_column(Integer)
    download_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    password_hash: Mapped[str | None] = mapped_column(Text)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    file: Mapped[File] = relationship(back_populates="shared_links")
    user: Mapped[User] = relationship()

    @property
    def requires_password(self) -> bool:
        return self.password_hash is not None

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<SharedLink {self.id} file={self.file_id}>"
