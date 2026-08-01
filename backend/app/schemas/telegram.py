"""Schemas for binding a Telegram channel."""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator


class TelegramConfigIn(BaseModel):
    bot_token: str = Field(
        ...,
        min_length=20,
        max_length=200,
        description="The HTTP API token from @BotFather",
        examples=["123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"],
    )
    channel_id: int = Field(
        ...,
        description="Numeric channel id from @userinfobot, e.g. -1001234567890",
        examples=[-1001234567890],
    )
    channel_name: str | None = Field(default=None, max_length=255)

    @field_validator("bot_token")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()

    @field_validator("channel_id")
    @classmethod
    def _reject_positive_ids(cls, v: int) -> int:
        # Supergroup/channel ids are always negative. A positive value is almost
        # always a user id pasted by mistake, and failing here beats a confusing
        # "chat not found" from Telegram three screens later.
        if v >= 0:
            raise ValueError(
                "channel_id must be negative (a channel id looks like -1001234567890)"
            )
        return v


class TelegramConfigOut(BaseModel):
    """The stored binding. The bot token is never returned, only a hint."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    channel_id: int
    channel_name: str | None
    bot_username: str | None
    bot_token_masked: str
    is_active: bool
    last_tested_at: datetime | None
    last_test_ok: bool | None
    created_at: datetime


class TelegramTestOut(BaseModel):
    ok: bool
    bot_username: str | None = None
    channel_title: str | None = None
    message_id: int | None = None
    detail: str | None = None
