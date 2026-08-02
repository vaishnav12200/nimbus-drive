"""Users, their Telegram binding, and refresh-token sessions."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import TYPE_CHECKING, Any

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import INET, JSONB
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.models.file import File
    from app.models.folder import Folder


class User(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "users"

    email: Mapped[str] = mapped_column(String(320), nullable=False, unique=True)
    # NULL for accounts that only ever authenticate through an OAuth provider.
    password_hash: Mapped[str | None] = mapped_column(Text)
    display_name: Mapped[str | None] = mapped_column(String(120))

    google_id: Mapped[str | None] = mapped_column(String(255), unique=True)
    github_id: Mapped[str | None] = mapped_column(String(255), unique=True)

    # Client-side encryption (spec §9.2). The backend stores only the public
    # parameters needed to *re-derive* a key on a new device — never the key,
    # never the password.
    encryption_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    encryption_salt: Mapped[bytes | None] = mapped_column(LargeBinary(32))

    # Which KDF produced the key, and with what cost parameters.
    #
    # The spec assumed one hard-coded algorithm. Recording it instead is what
    # makes the scheme upgradeable: raising Argon2's cost or moving off PBKDF2
    # later would otherwise silently break every existing file, because a key
    # derived with different parameters is a different key and there is no
    # recovery path. Stored per user, so an upgrade can be rolled out lazily.
    encryption_kdf: Mapped[str | None] = mapped_column(String(32))
    encryption_kdf_params: Mapped[dict[str, Any] | None] = mapped_column(JSONB)

    # Opaque client-produced ciphertext of a known plaintext.
    #
    # AES-GCM already authenticates, so a wrong password fails closed — but only
    # once the user has downloaded a file. On a fresh device this lets the unlock
    # screen reject a wrong password immediately, before anything is fetched.
    # The backend never interprets it.
    encryption_verifier: Mapped[bytes | None] = mapped_column(LargeBinary)

    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    telegram_configs: Mapped[list[UserTelegramConfig]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="selectin"
    )
    files: Mapped[list[File]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="noload"
    )
    folders: Mapped[list[Folder]] = relationship(
        back_populates="user", cascade="all, delete-orphan", lazy="noload"
    )

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<User {self.id}>"


class UserTelegramConfig(UUIDMixin, TimestampMixin, Base):
    """A bound Telegram channel: the user's storage bucket.

    ``bot_token_encrypted`` holds an AES-256-GCM ciphertext produced by
    :mod:`app.core.crypto`. The plaintext token never touches the database, a log
    line, or an API response (cross-cutting rule 3).
    """

    __tablename__ = "user_telegram_configs"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "channel_id", name="uq_user_telegram_configs_user_id_channel_id"
        ),
        Index("ix_user_telegram_configs_user_id_is_active", "user_id", "is_active"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    bot_token_encrypted: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    # Last 4 characters of the token, for a masked display like "…AbCd".
    bot_token_hint: Mapped[str | None] = mapped_column(String(8))
    bot_username: Mapped[str | None] = mapped_column(String(64))

    channel_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    channel_name: Mapped[str | None] = mapped_column(String(255))

    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true"
    )
    last_tested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_test_ok: Mapped[bool | None] = mapped_column(Boolean)

    user: Mapped[User] = relationship(back_populates="telegram_configs")


class RefreshToken(UUIDMixin, Base):
    """One row per issued refresh token, for rotation and reuse detection.

    Not in the spec's eight tables, but the spec asks for rotating refresh tokens
    with reuse detection — that is unimplementable without server-side state, and
    Redis is optional in this deployment. Tokens are stored as SHA-256 digests, so
    a database dump does not yield usable credentials.

    ``family_id`` links every token descended from one login. Presenting an
    already-rotated token revokes the whole family.
    """

    __tablename__ = "refresh_tokens"
    __table_args__ = (
        Index("ix_refresh_tokens_user_id_family_id", "user_id", "family_id"),
        Index("ix_refresh_tokens_expires_at", "expires_at"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    family_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    jti: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), nullable=False, unique=True
    )

    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    # Set the moment the token is exchanged; a second exchange is reuse.
    rotated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    user_agent: Mapped[str | None] = mapped_column(String(512))
    ip_address: Mapped[str | None] = mapped_column(INET)

    @property
    def is_usable(self) -> bool:
        return self.rotated_at is None and self.revoked_at is None
