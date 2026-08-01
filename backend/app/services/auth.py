"""Registration, login, and the rotating refresh-token session lifecycle."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.db import rowcount
from app.core.errors import (
    EmailAlreadyRegisteredError,
    InvalidCredentialsError,
    InvalidTokenError,
    TokenReuseError,
)
from app.core.logging import get_logger, hashed_user_id
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_refresh_token,
    needs_rehash,
    verify_password,
)
from app.models import RefreshToken, User

log = get_logger(__name__)


@dataclass(frozen=True)
class IssuedSession:
    access_token: str
    refresh_token: str
    expires_in: int


def _normalize_email(email: str) -> str:
    return email.strip().lower()


async def get_user_by_email(session: AsyncSession, email: str) -> User | None:
    result = await session.execute(
        select(User).where(User.email == _normalize_email(email))
    )
    return result.scalar_one_or_none()


async def get_user_by_id(session: AsyncSession, user_id: uuid.UUID) -> User | None:
    return await session.get(User, user_id)


# --- Registration & login ---------------------------------------------


async def register(
    session: AsyncSession,
    *,
    email: str,
    password: str,
    display_name: str | None = None,
) -> User:
    email = _normalize_email(email)
    user = User(
        email=email,
        password_hash=hash_password(password),
        display_name=display_name,
    )
    session.add(user)
    try:
        await session.flush()
    except IntegrityError as exc:
        # Losing the race against a concurrent signup for the same address is a
        # conflict, not a 500 — the unique index is the real arbiter.
        await session.rollback()
        raise EmailAlreadyRegisteredError(details={"email": email}) from exc

    log.info("user_registered", user=hashed_user_id(user.id))
    return user


async def authenticate(session: AsyncSession, *, email: str, password: str) -> User:
    user = await get_user_by_email(session, email)

    # Verify even when the user does not exist so a missing account and a wrong
    # password take the same amount of time and return the same error.
    if not verify_password(password, user.password_hash if user else None):
        raise InvalidCredentialsError()
    assert user is not None

    if not user.is_active:
        raise InvalidCredentialsError("This account has been disabled")

    # Transparently upgrade hashes when the Argon2 parameters are raised.
    if user.password_hash and needs_rehash(user.password_hash):
        user.password_hash = hash_password(password)

    user.last_login_at = datetime.now(UTC)
    await session.flush()
    return user


# --- OAuth account resolution -----------------------------------------


async def upsert_oauth_user(
    session: AsyncSession,
    *,
    provider: str,
    provider_user_id: str,
    email: str,
    display_name: str | None = None,
) -> User:
    """Find or create the account behind a verified OAuth identity.

    Matching falls back to email so a user who registered with a password can
    later sign in with Google without ending up with two accounts. That is only
    safe because both providers verify the address before we get here.
    """
    column = User.google_id if provider == "google" else User.github_id
    result = await session.execute(select(User).where(column == provider_user_id))
    user = result.scalar_one_or_none()

    if user is None:
        user = await get_user_by_email(session, email)

    if user is None:
        user = User(
            email=_normalize_email(email),
            display_name=display_name,
            password_hash=None,
        )
        session.add(user)

    setattr(user, "google_id" if provider == "google" else "github_id", provider_user_id)
    if display_name and not user.display_name:
        user.display_name = display_name
    user.last_login_at = datetime.now(UTC)

    await session.flush()
    return user


# --- Sessions ----------------------------------------------------------


async def issue_session(
    session: AsyncSession,
    user: User,
    *,
    family_id: uuid.UUID | None = None,
    user_agent: str | None = None,
    ip_address: str | None = None,
) -> IssuedSession:
    """Mint an access token plus a fresh refresh token.

    Passing ``family_id`` continues an existing login chain (a rotation); omitting
    it starts a new one (a fresh login).
    """
    access = create_access_token(user_id=user.id, email=user.email)

    raw_refresh = generate_refresh_token()
    now = datetime.now(UTC)
    session.add(
        RefreshToken(
            user_id=user.id,
            family_id=family_id or uuid.uuid4(),
            token_hash=hash_refresh_token(raw_refresh),
            jti=uuid.uuid4(),
            issued_at=now,
            expires_at=now + timedelta(days=settings.refresh_token_ttl_days),
            user_agent=(user_agent or None) and user_agent[:512],
            ip_address=ip_address,
        )
    )
    await session.flush()

    return IssuedSession(
        access_token=access.token,
        refresh_token=raw_refresh,
        expires_in=access.expires_in,
    )


async def rotate_refresh_token(
    session: AsyncSession,
    raw_token: str,
    *,
    user_agent: str | None = None,
    ip_address: str | None = None,
) -> IssuedSession:
    """Exchange a refresh token for a new pair, invalidating the old one.

    A token that has already been rotated means the holder is replaying a value
    someone else has consumed — either a stolen token or a race with a real
    client. Both are handled the same way: revoke the entire family, forcing a
    genuine re-login. This is the standard OAuth 2.1 reuse-detection response.
    """
    token_hash = hash_refresh_token(raw_token)
    result = await session.execute(
        select(RefreshToken).where(RefreshToken.token_hash == token_hash)
    )
    stored = result.scalar_one_or_none()

    if stored is None:
        raise InvalidTokenError("The refresh token is not recognised")

    if stored.rotated_at is not None:
        await revoke_family(session, stored.family_id)
        # Commit before raising. The request's unit of work rolls back on any
        # exception, which would undo the revocation we just performed and leave
        # reuse detection reporting a breach it did not actually contain.
        await session.commit()
        log.warning(
            "refresh_token_reuse_detected",
            user=hashed_user_id(stored.user_id),
            family=str(stored.family_id),
        )
        raise TokenReuseError()

    if stored.revoked_at is not None:
        raise InvalidTokenError("This session has been revoked")

    if stored.expires_at <= datetime.now(UTC):
        raise InvalidTokenError("The refresh token has expired")

    user = await session.get(User, stored.user_id)
    if user is None or not user.is_active:
        raise InvalidTokenError("The account is no longer active")

    stored.rotated_at = datetime.now(UTC)
    return await issue_session(
        session,
        user,
        family_id=stored.family_id,
        user_agent=user_agent,
        ip_address=ip_address,
    )


async def revoke_refresh_token(session: AsyncSession, raw_token: str) -> bool:
    """Log out one session. Returns False if the token was already unusable."""
    result = await session.execute(
        select(RefreshToken).where(
            RefreshToken.token_hash == hash_refresh_token(raw_token)
        )
    )
    stored = result.scalar_one_or_none()
    if stored is None or not stored.is_usable:
        return False
    stored.revoked_at = datetime.now(UTC)
    await session.flush()
    return True


async def revoke_family(session: AsyncSession, family_id: uuid.UUID) -> None:
    await session.execute(
        update(RefreshToken)
        .where(RefreshToken.family_id == family_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=datetime.now(UTC))
    )
    await session.flush()


async def revoke_all_sessions(session: AsyncSession, user_id: uuid.UUID) -> int:
    result = await session.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=datetime.now(UTC))
    )
    await session.flush()
    return rowcount(result)


async def list_sessions(session: AsyncSession, user_id: uuid.UUID) -> list[RefreshToken]:
    result = await session.execute(
        select(RefreshToken)
        .where(
            RefreshToken.user_id == user_id,
            RefreshToken.revoked_at.is_(None),
            RefreshToken.rotated_at.is_(None),
            RefreshToken.expires_at > datetime.now(UTC),
        )
        .order_by(RefreshToken.issued_at.desc())
    )
    return list(result.scalars().all())


async def purge_expired_tokens(session: AsyncSession) -> int:
    """Delete refresh tokens that can no longer be presented.

    Rotated rows are kept for a full token lifetime after rotation so reuse
    detection still has something to match against; only genuinely dead rows go.
    """
    from sqlalchemy import delete

    cutoff = datetime.now(UTC) - timedelta(days=settings.refresh_token_ttl_days)
    result = await session.execute(
        delete(RefreshToken).where(RefreshToken.expires_at < cutoff)
    )
    return rowcount(result)
