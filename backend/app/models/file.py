"""Files, their chunk manifests and their tags — the centre of gravity."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, UUIDMixin
from app.models.enums import StorageProvider

if TYPE_CHECKING:
    from app.models.folder import Folder
    from app.models.share import SharedLink
    from app.models.user import User


class File(UUIDMixin, TimestampMixin, Base):
    """Metadata for one stored file. The bytes live in the user's Telegram channel.

    Two storage shapes are possible:

    * **whole** — ``telegram_message_id``/``telegram_file_id`` point at a single
      Telegram message (uploads ≤ 20 MB, sent straight from the client).
    * **chunked** — ``is_chunked`` is true and the ordered ``chunks`` rows form the
      manifest (uploads > 20 MB, segmented by the backend over MTProto).

    ``sha256`` always hashes the **plaintext**, even when ``is_encrypted`` is set,
    so deduplication still works for encrypted uploads (cross-cutting rule 5).
    """

    __tablename__ = "files"
    __table_args__ = (
        CheckConstraint("size >= 0", name="size_non_negative"),
        CheckConstraint(
            "(is_chunked AND chunk_count > 0) OR (NOT is_chunked AND chunk_count = 0)",
            name="chunk_count_matches_is_chunked",
        ),
        CheckConstraint(
            "(is_deleted AND deleted_at IS NOT NULL)"
            " OR (NOT is_deleted AND deleted_at IS NULL)",
            name="deleted_at_matches_is_deleted",
        ),
        # Spec §8.4 index set.
        Index(
            "ix_files_user_id_folder_id_is_deleted_created_at",
            "user_id",
            "folder_id",
            "is_deleted",
            "created_at",
        ),
        Index("ix_files_user_id_size", "user_id", "size"),
        # Added beyond the spec: dedup queries `sha256` on every upload, and the
        # sync endpoint scans by `updated_at`. Both were unindexed.
        Index("ix_files_user_id_sha256", "user_id", "sha256"),
        Index("ix_files_user_id_updated_at", "user_id", "updated_at"),
        # Lets the purge job answer "does any other row still reference this
        # Telegram message?" before deleting remote bytes.
        Index(
            "ix_files_telegram_channel_id_telegram_message_id",
            "telegram_channel_id",
            "telegram_message_id",
            postgresql_where=text("telegram_message_id IS NOT NULL"),
        ),
        # Partial index for the trash purge sweep.
        Index(
            "ix_files_deleted_at",
            "deleted_at",
            postgresql_where=text("is_deleted"),
        ),
        # The trigram index on `name` needs the pg_trgm extension; it is created
        # with raw DDL in the initial migration.
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    # SET NULL, not CASCADE: deleting a folder must never silently destroy the
    # only record of where a user's bytes live. Orphans fall back to the root.
    folder_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("folders.id", ondelete="SET NULL")
    )

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    original_name: Mapped[str] = mapped_column(String(255), nullable=False)
    size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    mime_type: Mapped[str] = mapped_column(
        String(255), nullable=False, default="application/octet-stream"
    )
    sha256: Mapped[str | None] = mapped_column(String(64))

    storage_provider: Mapped[str] = mapped_column(
        String(32),
        nullable=False,
        default=StorageProvider.TELEGRAM,
        server_default=StorageProvider.TELEGRAM.value,
    )

    telegram_message_id: Mapped[int | None] = mapped_column(BigInteger)
    telegram_file_id: Mapped[str | None] = mapped_column(Text)
    telegram_file_unique_id: Mapped[str | None] = mapped_column(String(64))
    telegram_channel_id: Mapped[int | None] = mapped_column(BigInteger)

    is_chunked: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    chunk_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )

    is_encrypted: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    is_favorite: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    is_deleted: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    folder: Mapped[Folder | None] = relationship(back_populates="files")
    user: Mapped[User] = relationship(back_populates="files")
    chunks: Mapped[list[FileChunk]] = relationship(
        back_populates="file",
        cascade="all, delete-orphan",
        order_by="FileChunk.chunk_index",
        lazy="selectin",
    )
    tags: Mapped[list[FileTag]] = relationship(
        back_populates="file", cascade="all, delete-orphan", lazy="selectin"
    )
    shared_links: Mapped[list[SharedLink]] = relationship(
        back_populates="file", cascade="all, delete-orphan", lazy="noload"
    )

    @property
    def tag_names(self) -> list[str]:
        return sorted(t.tag for t in self.tags)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<File {self.id} {self.name!r}>"


class FileChunk(UUIDMixin, Base):
    """One 19 MB segment of a chunked file, as a single Telegram message."""

    __tablename__ = "file_chunks"
    __table_args__ = (
        UniqueConstraint(
            "file_id", "chunk_index", name="uq_file_chunks_file_id_chunk_index"
        ),
        CheckConstraint("chunk_index >= 0", name="chunk_index_non_negative"),
        CheckConstraint("size > 0", name="chunk_size_positive"),
        Index("ix_file_chunks_file_id_chunk_index", "file_id", "chunk_index"),
    )

    file_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey("files.id", ondelete="CASCADE"), nullable=False
    )
    chunk_index: Mapped[int] = mapped_column(Integer, nullable=False)
    size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    # Byte offset of this chunk within the reassembled file. Stored rather than
    # summed at read time so a Range request can binary-search straight to the
    # chunk holding a given offset.
    offset: Mapped[int] = mapped_column(
        BigInteger, nullable=False, default=0, server_default="0"
    )

    telegram_message_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    telegram_file_id: Mapped[str | None] = mapped_column(Text)
    telegram_file_unique_id: Mapped[str | None] = mapped_column(String(64))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now()"), nullable=False
    )

    file: Mapped[File] = relationship(back_populates="chunks")

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<FileChunk {self.file_id}#{self.chunk_index}>"


class FileTag(Base):
    """Free-form label on a file. Composite primary key, no surrogate id."""

    __tablename__ = "file_tags"
    __table_args__ = (Index("ix_file_tags_tag", "tag"),)

    file_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey("files.id", ondelete="CASCADE"),
        primary_key=True,
    )
    tag: Mapped[str] = mapped_column(String(64), primary_key=True)

    file: Mapped[File] = relationship(back_populates="tags")
