"""Folders — a hierarchy that exists only in PostgreSQL; Telegram never sees it."""

from __future__ import annotations

import uuid
from typing import TYPE_CHECKING

from sqlalchemy import ForeignKey, Index, String, Text, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.models.file import File
    from app.models.user import User

PATH_SEPARATOR = "/"


class Folder(UUIDMixin, TimestampMixin, Base):
    """A node in the user's folder tree.

    ``path`` is materialized (e.g. ``/Documents/Work/2026``) so breadcrumbs and
    subtree queries are a single indexed prefix scan instead of a recursive CTE.
    It is derived state: every write that changes a name or a parent must
    recompute it for the node *and every descendant* — see
    :mod:`app.services.folders`.
    """

    __tablename__ = "folders"
    __table_args__ = (
        # Sibling names are unique. Two constraints are needed because NULL is
        # never equal to NULL in a composite unique index, so root-level folders
        # would otherwise escape the check entirely.
        UniqueConstraint(
            "user_id", "parent_id", "name", name="uq_folders_user_id_parent_id_name"
        ),
        Index(
            "uq_folders_user_id_name_root",
            "user_id",
            "name",
            unique=True,
            postgresql_where=text("parent_id IS NULL"),
        ),
        Index("ix_folders_user_id_parent_id", "user_id", "parent_id"),
        Index("ix_folders_user_id_path", "user_id", "path"),
        Index("ix_folders_user_id_updated_at", "user_id", "updated_at"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("folders.id", ondelete="CASCADE")
    )

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    color: Mapped[str | None] = mapped_column(String(9))  # #RRGGBB or #RRGGBBAA
    path: Mapped[str] = mapped_column(Text, nullable=False)

    user: Mapped[User] = relationship(back_populates="folders")
    parent: Mapped[Folder | None] = relationship(
        back_populates="children", remote_side="Folder.id"
    )
    children: Mapped[list[Folder]] = relationship(
        back_populates="parent", cascade="all, delete-orphan", lazy="noload"
    )
    files: Mapped[list[File]] = relationship(back_populates="folder", lazy="noload")

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<Folder {self.path!r}>"
