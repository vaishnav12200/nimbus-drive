"""Telegram channel binding (spec §2.2 of the build plan)."""

from __future__ import annotations

from fastapi import APIRouter, status

from app.api.deps import ContextDep, CurrentUser, SessionDep
from app.core.envelope import Ack, Envelope, ok
from app.core.errors import TelegramError
from app.models import ActivityAction
from app.schemas.telegram import TelegramConfigIn, TelegramConfigOut, TelegramTestOut
from app.services import activity
from app.services import telegram_config as config_service

router = APIRouter(prefix="/telegram", tags=["telegram"])


def _out(config: object) -> TelegramConfigOut:
    return TelegramConfigOut(
        id=config.id,  # type: ignore[attr-defined]
        channel_id=config.channel_id,  # type: ignore[attr-defined]
        channel_name=config.channel_name,  # type: ignore[attr-defined]
        bot_username=config.bot_username,  # type: ignore[attr-defined]
        bot_token_masked=config_service.mask_token(config.bot_token_hint),  # type: ignore[attr-defined]
        is_active=config.is_active,  # type: ignore[attr-defined]
        last_tested_at=config.last_tested_at,  # type: ignore[attr-defined]
        last_test_ok=config.last_test_ok,  # type: ignore[attr-defined]
        created_at=config.created_at,  # type: ignore[attr-defined]
    )


@router.post(
    "/config",
    response_model=Envelope[TelegramConfigOut],
    status_code=status.HTTP_201_CREATED,
    summary="Bind a Telegram channel",
)
async def set_config(
    payload: TelegramConfigIn,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
) -> Envelope[TelegramConfigOut]:
    """Store the bot token (encrypted) and channel id for this account.

    The token is validated against `getMe` first, so a typo fails here rather
    than on the user's first upload.
    """
    config = await config_service.bind_channel(
        session,
        user.id,
        bot_token=payload.bot_token,
        channel_id=payload.channel_id,
        channel_name=payload.channel_name,
    )
    await activity.record(
        session,
        action=ActivityAction.TELEGRAM_BIND,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"channel_id": payload.channel_id},
    )
    return ok(_out(config))


@router.get(
    "/config",
    response_model=Envelope[TelegramConfigOut],
    summary="Read the active binding",
)
async def get_config(
    session: SessionDep, user: CurrentUser
) -> Envelope[TelegramConfigOut]:
    """Returns the binding with the bot token masked — never in plaintext."""
    config = await config_service.require_active_config(session, user.id)
    return ok(_out(config))


@router.post(
    "/test",
    response_model=Envelope[TelegramTestOut],
    summary="Test the binding end to end",
)
async def test_config(
    session: SessionDep, user: CurrentUser, ctx: ContextDep
) -> Envelope[TelegramTestOut]:
    """Runs `getMe`, `getChat`, then posts a message to the channel.

    Returns 200 with `ok: false` when Telegram rejects the attempt — the failure
    is expected user-configuration feedback, not a server error, and the detail
    string is what the onboarding screen shows.
    """
    config = await config_service.require_active_config(session, user.id)
    try:
        succeeded, details = await config_service.test_connection(session, config)
    except TelegramError as exc:
        await activity.record(
            session,
            action=ActivityAction.TELEGRAM_TEST,
            user_id=user.id,
            ip_address=ctx.ip_address,
            user_agent=ctx.user_agent,
            details={"ok": False, "code": exc.code},
        )
        return ok(TelegramTestOut(ok=False, detail=exc.message))

    await activity.record(
        session,
        action=ActivityAction.TELEGRAM_TEST,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"ok": succeeded},
    )
    return ok(
        TelegramTestOut(
            ok=succeeded,
            bot_username=details.get("bot_username"),  # type: ignore[arg-type]
            channel_title=details.get("channel_title"),  # type: ignore[arg-type]
            message_id=details.get("message_id"),  # type: ignore[arg-type]
        )
    )


@router.delete(
    "/config",
    response_model=Envelope[Ack],
    summary="Unbind the active channel",
)
async def delete_config(session: SessionDep, user: CurrentUser) -> Envelope[Ack]:
    """Deactivates the binding. Existing file metadata is left untouched."""
    config = await config_service.require_active_config(session, user.id)
    await config_service.unbind(session, config)
    return ok(Ack())
