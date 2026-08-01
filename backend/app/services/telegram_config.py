"""Binding a user's Telegram channel, and reading the credential back out."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.crypto import DecryptionError, decrypt, encrypt
from app.core.errors import BadRequestError, StorageError, TelegramConfigMissingError
from app.core.logging import get_logger
from app.models import UserTelegramConfig
from app.providers.base import StorageCredentials
from app.providers.telegram import TelegramStorage, looks_like_bot_token

log = get_logger(__name__)

CONNECTION_TEST_MESSAGE = "✅ Nimbus Drive connected"


def _aad(user_id: uuid.UUID) -> bytes:
    """Bind the ciphertext to its owner.

    Without this, a row moved between users would still decrypt — the AAD makes
    a swapped `user_id` an authentication failure rather than a silent success.
    """
    return f"telegram-bot-token:{user_id}".encode()


def mask_token(hint: str | None) -> str:
    return f"••••••••{hint}" if hint else "••••••••"


async def get_active_config(
    session: AsyncSession, user_id: uuid.UUID
) -> UserTelegramConfig | None:
    result = await session.execute(
        select(UserTelegramConfig)
        .where(
            UserTelegramConfig.user_id == user_id,
            UserTelegramConfig.is_active.is_(True),
        )
        .order_by(UserTelegramConfig.created_at.desc())
        .limit(1)
    )
    return result.scalar_one_or_none()


async def require_active_config(
    session: AsyncSession, user_id: uuid.UUID
) -> UserTelegramConfig:
    config = await get_active_config(session, user_id)
    if config is None:
        raise TelegramConfigMissingError()
    return config


async def get_credentials(
    session: AsyncSession, user_id: uuid.UUID
) -> StorageCredentials:
    """Decrypt the bot token for one request's use. Never cache the result."""
    config = await require_active_config(session, user_id)
    return credentials_from(config)


def credentials_from(config: UserTelegramConfig) -> StorageCredentials:
    try:
        token = decrypt(config.bot_token_encrypted, aad=_aad(config.user_id))
    except DecryptionError as exc:
        # Almost always a rotated or lost SECRET_ENCRYPTION_KEY. Say so plainly:
        # the fix is re-binding the channel, not retrying.
        log.error("bot_token_decrypt_failed", config_id=str(config.id))
        raise StorageError(
            "The stored bot token could not be decrypted. Re-bind the channel "
            "to fix this (the server's encryption key may have changed).",
            code="BOT_TOKEN_UNREADABLE",
        ) from exc
    return StorageCredentials(bot_token=token, channel_id=config.channel_id)


async def bind_channel(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    bot_token: str,
    channel_id: int,
    channel_name: str | None = None,
    verify: bool = True,
) -> UserTelegramConfig:
    """Store (or replace) the user's channel binding.

    When ``verify`` is set the token is checked against `getMe` before anything
    is written, so an invalid binding never reaches the database.
    """
    if not looks_like_bot_token(bot_token):
        raise BadRequestError(
            "That does not look like a bot token. It should look like "
            "123456789:AA... — copy the whole line from @BotFather.",
            code="BOT_TOKEN_MALFORMED",
        )

    bot_username: str | None = None
    if verify:
        me = await TelegramStorage.call(bot_token, "getMe")
        bot_username = me.get("username")

    existing = await _find_binding(session, user_id, channel_id)
    config = existing or UserTelegramConfig(user_id=user_id, channel_id=channel_id)

    config.bot_token_encrypted = encrypt(bot_token, aad=_aad(user_id))
    config.bot_token_hint = bot_token[-4:]
    config.bot_username = bot_username or config.bot_username
    config.channel_name = channel_name or config.channel_name
    config.is_active = True

    if existing is None:
        session.add(config)

    # A user has exactly one active channel at a time; binding a new one retires
    # the old binding rather than leaving two candidates for "where do uploads go".
    await _deactivate_others(session, user_id, keep=config)
    await session.flush()

    log.info("telegram_channel_bound", channel_id=channel_id)
    return config


async def _find_binding(
    session: AsyncSession, user_id: uuid.UUID, channel_id: int
) -> UserTelegramConfig | None:
    result = await session.execute(
        select(UserTelegramConfig).where(
            UserTelegramConfig.user_id == user_id,
            UserTelegramConfig.channel_id == channel_id,
        )
    )
    return result.scalar_one_or_none()


async def _deactivate_others(
    session: AsyncSession, user_id: uuid.UUID, *, keep: UserTelegramConfig
) -> None:
    result = await session.execute(
        select(UserTelegramConfig).where(
            UserTelegramConfig.user_id == user_id,
            UserTelegramConfig.is_active.is_(True),
        )
    )
    for row in result.scalars().all():
        if row is not keep:
            row.is_active = False


async def test_connection(
    session: AsyncSession, config: UserTelegramConfig
) -> tuple[bool, dict[str, object]]:
    """Verify the binding end to end: `getMe`, then actually post to the channel.

    `getMe` alone proves only that the token is live. Posting is what proves the
    bot is in the channel *and* has permission to write there, which is the part
    users get wrong.
    """
    credentials = credentials_from(config)
    details: dict[str, object] = {}
    ok = False

    try:
        me = await TelegramStorage.call(credentials.bot_token, "getMe")
        config.bot_username = me.get("username") or config.bot_username
        details["bot_username"] = config.bot_username

        chat = await TelegramStorage.call(
            credentials.bot_token,
            "getChat",
            data={"chat_id": str(credentials.channel_id)},
        )
        title = chat.get("title")
        if title:
            config.channel_name = config.channel_name or title
        details["channel_title"] = title

        sent = await TelegramStorage.call(
            credentials.bot_token,
            "sendMessage",
            data={
                "chat_id": str(credentials.channel_id),
                "text": CONNECTION_TEST_MESSAGE,
                "disable_notification": "true",
            },
        )
        details["message_id"] = sent.get("message_id")
        ok = True
    finally:
        config.last_tested_at = datetime.now(UTC)
        config.last_test_ok = ok
        await session.flush()

    return ok, details


async def unbind(session: AsyncSession, config: UserTelegramConfig) -> None:
    """Deactivate a binding without deleting it.

    The row is kept because existing file metadata still references this
    `channel_id`; dropping it would leave those files unattributable.
    """
    config.is_active = False
    await session.flush()
