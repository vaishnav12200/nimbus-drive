"""Public share links.

**Encrypted files cannot be shared.** With client-side encryption the key never
leaves the user's device, so a recipient following a link would download
ciphertext they have no way to read. The alternative — putting the key in the URL
fragment — is workable in principle (fragments are not sent to the server) but
needs a web client to do the decryption, and this project ships mobile only.
Refusing with a clear error beats handing someone a link that silently produces a
useless file. This resolves the open question in the build plan.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.errors import (
    BadRequestError,
    PermissionDeniedError,
    ShareExpiredError,
    ShareNotFoundError,
)
from app.core.logging import get_logger
from app.core.security import generate_share_token, hash_password, verify_password
from app.models import File, SharedLink

log = get_logger(__name__)


async def create_share(
    session: AsyncSession,
    user_id: uuid.UUID,
    file: File,
    *,
    expires_in: int | None = None,
    max_downloads: int | None = None,
    password: str | None = None,
) -> SharedLink:
    if file.is_deleted:
        raise BadRequestError(
            "A file in the trash cannot be shared", code="FILE_IN_TRASH"
        )
    if file.is_encrypted:
        raise BadRequestError(
            "Encrypted files cannot be shared: the recipient has no way to "
            "decrypt them. Upload an unencrypted copy to share it.",
            code="CANNOT_SHARE_ENCRYPTED",
        )

    share = SharedLink(
        file_id=file.id,
        user_id=user_id,
        token=generate_share_token(),
        expires_at=(
            datetime.now(UTC) + timedelta(seconds=expires_in) if expires_in else None
        ),
        max_downloads=max_downloads,
        password_hash=hash_password(password) if password else None,
    )
    session.add(share)
    await session.flush()
    log.info("share_created", share_id=str(share.id))
    return share


async def list_shares(
    session: AsyncSession, user_id: uuid.UUID
) -> list[tuple[SharedLink, File]]:
    result = await session.execute(
        select(SharedLink, File)
        .join(File, File.id == SharedLink.file_id)
        .where(SharedLink.user_id == user_id, SharedLink.revoked_at.is_(None))
        .order_by(SharedLink.created_at.desc())
    )
    return [(row[0], row[1]) for row in result]


async def get_owned_share(
    session: AsyncSession, user_id: uuid.UUID, share_id: uuid.UUID
) -> SharedLink:
    result = await session.execute(select(SharedLink).where(SharedLink.id == share_id))
    share = result.scalar_one_or_none()
    if share is None:
        raise ShareNotFoundError(details={"share_id": str(share_id)})
    if share.user_id != user_id:
        # Deliberately the same shape as "not found" — confirming that someone
        # else's share id exists is itself a small leak.
        raise ShareNotFoundError(details={"share_id": str(share_id)})
    return share


async def revoke(session: AsyncSession, share: SharedLink) -> None:
    if share.revoked_at is None:
        share.revoked_at = datetime.now(UTC)
        await session.flush()


async def resolve_token(session: AsyncSession, token: str) -> tuple[SharedLink, File]:
    """Look up a link by its public token and check it is still usable."""
    result = await session.execute(
        select(SharedLink)
        .options(selectinload(SharedLink.file).selectinload(File.chunks))
        .where(SharedLink.token == token)
    )
    share = result.scalar_one_or_none()
    if share is None:
        raise ShareNotFoundError()

    if share.revoked_at is not None:
        raise ShareNotFoundError()

    if share.expires_at is not None and share.expires_at <= datetime.now(UTC):
        raise ShareExpiredError("This share link has expired")

    if share.max_downloads is not None and share.download_count >= share.max_downloads:
        raise ShareExpiredError("This share link has reached its download limit")

    file = share.file
    if file is None or file.is_deleted:
        raise ShareNotFoundError("The shared file is no longer available")

    return share, file


def check_password(share: SharedLink, supplied: str | None) -> None:
    if share.password_hash is None:
        return
    if not supplied:
        raise PermissionDeniedError(
            "This link requires a password", code="SHARE_PASSWORD_REQUIRED"
        )
    if not verify_password(supplied, share.password_hash):
        raise PermissionDeniedError("Incorrect password", code="SHARE_PASSWORD_INVALID")


async def consume_download(session: AsyncSession, share: SharedLink) -> None:
    """Atomically claim one download against the link's quota.

    The check and the increment have to be one statement: two concurrent requests
    that both read `download_count == max_downloads - 1` would otherwise both
    proceed, serving one more download than the owner allowed.
    """
    result = await session.execute(
        update(SharedLink)
        .where(
            SharedLink.id == share.id,
            SharedLink.revoked_at.is_(None),
            (SharedLink.max_downloads.is_(None))
            | (SharedLink.download_count < SharedLink.max_downloads),
        )
        .values(download_count=SharedLink.download_count + 1)
        .returning(SharedLink.download_count)
    )
    if result.scalar_one_or_none() is None:
        raise ShareExpiredError("This share link has reached its download limit")
    await session.flush()


def downloads_remaining(share: SharedLink) -> int | None:
    if share.max_downloads is None:
        return None
    return max(0, share.max_downloads - share.download_count)
