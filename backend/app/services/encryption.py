"""Custody of client-side encryption parameters.

Deliberately small. Everything cryptographic happens on the device: the password
is never transmitted, the key is derived locally, and files are sealed before
they leave. What lives here is the handful of *public* values a second device
needs in order to arrive at the same key — plus the rules that stop a user
destroying their own data.

Two of those rules matter:

* Enabling twice would issue a new salt, and every file encrypted under the old
  one would become permanently unreadable. Refused.
* Disabling while encrypted files exist would leave rows whose bytes nobody can
  decrypt. Refused until the trash is empty of them too.
"""

from __future__ import annotations

import base64
import os
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import BadRequestError, ConflictError
from app.core.logging import get_logger, hashed_user_id
from app.models import File, User
from app.schemas.encryption import SALT_BYTES, Kdf

log = get_logger(__name__)


async def count_encrypted_files(
    session: AsyncSession, user_id: uuid.UUID, *, include_trashed: bool = True
) -> int:
    conditions = [File.user_id == user_id, File.is_encrypted.is_(True)]
    if not include_trashed:
        conditions.append(File.is_deleted.is_(False))
    return int(
        await session.scalar(select(func.count()).select_from(File).where(*conditions))
        or 0
    )


async def enable(
    session: AsyncSession,
    user: User,
    *,
    kdf: Kdf,
    kdf_params: dict[str, int],
    verifier: str | None = None,
) -> User:
    """Turn on encryption: mint a salt and record how to use it.

    The salt is generated server-side from `os.urandom` rather than accepted
    from the client — it is the one value here whose unpredictability the server
    can actually guarantee, and a client with a weak RNG would silently weaken
    every key it derives.
    """
    if user.encryption_enabled:
        raise ConflictError(
            "Encryption is already enabled. Generating a new salt would make "
            "every already-encrypted file permanently unreadable.",
            code="ENCRYPTION_ALREADY_ENABLED",
        )

    user.encryption_salt = os.urandom(SALT_BYTES)
    user.encryption_kdf = str(kdf)
    user.encryption_kdf_params = dict(kdf_params)
    user.encryption_verifier = base64.b64decode(verifier) if verifier else None
    user.encryption_enabled = True
    await session.flush()

    log.info(
        "encryption_enabled",
        user=hashed_user_id(user.id),
        kdf=str(kdf),
        # Cost parameters are not secret and are useful when diagnosing a slow
        # unlock on an old device.
        kdf_params=kdf_params,
    )
    return user


async def describe(session: AsyncSession, user: User) -> dict[str, Any]:
    """The parameters a client needs to re-derive its key."""
    return {
        "enabled": user.encryption_enabled,
        "kdf": user.encryption_kdf,
        "kdf_params": user.encryption_kdf_params,
        "salt": (
            base64.b64encode(user.encryption_salt).decode()
            if user.encryption_salt
            else None
        ),
        "verifier": (
            base64.b64encode(user.encryption_verifier).decode()
            if user.encryption_verifier
            else None
        ),
        "encrypted_file_count": await count_encrypted_files(session, user.id),
    }


async def set_verifier(session: AsyncSession, user: User, verifier: str) -> User:
    """Attach or replace the password-check blob.

    Separate from `enable` so a client that adopted encryption before it had a
    verifier can add one later without a destructive re-enable.
    """
    if not user.encryption_enabled:
        raise BadRequestError(
            "Encryption is not enabled for this account",
            code="ENCRYPTION_NOT_ENABLED",
        )
    user.encryption_verifier = base64.b64decode(verifier)
    await session.flush()
    return user


async def disable(session: AsyncSession, user: User, *, force: bool = False) -> User:
    """Turn encryption off, refusing while it would strand data.

    ``force`` is the deliberate escape hatch for a user who has lost the
    password and accepts that the remaining files are gone. It still does not
    delete anything — the rows stay, flagged, and the trash can be emptied
    normally.
    """
    if not user.encryption_enabled:
        raise BadRequestError(
            "Encryption is not enabled for this account",
            code="ENCRYPTION_NOT_ENABLED",
        )

    remaining = await count_encrypted_files(session, user.id)
    if remaining and not force:
        raise ConflictError(
            f"{remaining} encrypted file(s) still exist, including any in the "
            "trash. Download and re-upload them unencrypted first, or pass "
            "force=true to accept that they become unreadable.",
            code="ENCRYPTION_IN_USE",
            details={"encrypted_file_count": remaining},
        )

    user.encryption_enabled = False
    user.encryption_salt = None
    user.encryption_kdf = None
    user.encryption_kdf_params = None
    user.encryption_verifier = None
    await session.flush()

    log.warning(
        "encryption_disabled",
        user=hashed_user_id(user.id),
        orphaned_files=remaining,
        forced=force,
    )
    return user


def assert_can_store_encrypted(user: User) -> None:
    """Guard the upload path.

    Accepting ``is_encrypted: true`` from an account with no stored salt would
    record a file nobody can ever decrypt — the client's key came from
    somewhere the server cannot describe to a second device.
    """
    if not user.encryption_enabled:
        raise BadRequestError(
            "This file is marked encrypted but encryption is not enabled for "
            "the account. Call POST /api/encryption first so the salt is stored, "
            "otherwise the file could never be decrypted on another device.",
            code="ENCRYPTION_NOT_ENABLED",
        )


def enabled_at(user: User) -> datetime | None:
    """Best available timestamp for when encryption was switched on.

    There is no dedicated column; `updated_at` is the closest honest answer and
    only meaningful while encryption is on.
    """
    return user.updated_at if user.encryption_enabled else None


def now() -> datetime:  # pragma: no cover - injection point for tests
    return datetime.now(UTC)
