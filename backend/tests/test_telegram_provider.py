"""Telegram error mapping and token validation.

Telegram signals every failure as `{"ok": false, "description": "..."}`, which is
prose meant for humans. These tests pin the translation into the stable
`error.code` values clients switch on.
"""

from __future__ import annotations

import pytest

from app.core.errors import (
    PayloadTooLargeError,
    TelegramError,
    TelegramFloodWaitError,
)
from app.providers.telegram import TelegramStorage, looks_like_bot_token


@pytest.mark.parametrize(
    ("description", "status", "expected_code"),
    [
        ("Bad Request: chat not found", 400, "CHANNEL_INVALID"),
        ("Forbidden: bot was blocked by the user", 403, "BOT_BLOCKED"),
        ("Bad Request: not enough rights to send documents", 400, "CHAT_WRITE_FORBIDDEN"),
        ("Unauthorized", 401, "BOT_TOKEN_INVALID"),
        ("Bad Request: something else entirely", 400, "TELEGRAM_ERROR"),
    ],
)
def test_error_descriptions_map_to_stable_codes(
    description: str, status: int, expected_code: str
) -> None:
    with pytest.raises(TelegramError) as info:
        TelegramStorage._raise_for_telegram({"description": description}, status)
    assert info.value.code == expected_code


def test_flood_wait_carries_the_retry_delay() -> None:
    """Telegram tells us exactly how long to back off; that has to reach the client."""
    with pytest.raises(TelegramFloodWaitError) as info:
        TelegramStorage._raise_for_telegram(
            {"description": "Too Many Requests", "parameters": {"retry_after": 42}}, 429
        )
    assert info.value.details["retry_after"] == 42
    assert info.value.headers["Retry-After"] == "42"
    assert info.value.status_code == 429


def test_oversized_file_maps_to_413() -> None:
    with pytest.raises(PayloadTooLargeError) as info:
        TelegramStorage._raise_for_telegram(
            {"description": "Request Entity Too Large: file is too big"}, 413
        )
    assert info.value.code == "FILE_TOO_LARGE"


def test_a_missing_description_still_produces_an_error() -> None:
    with pytest.raises(TelegramError):
        TelegramStorage._raise_for_telegram({}, 500)


@pytest.mark.parametrize(
    "token",
    [
        "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw",
        "8000000000:AAF-lkjhgfdsaQWERTYUIOPzxcvbnm123456",
    ],
)
def test_valid_bot_tokens_are_accepted(token: str) -> None:
    assert looks_like_bot_token(token)


@pytest.mark.parametrize(
    "token",
    [
        "",
        "not-a-token",
        "123:short",
        "AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw",  # missing the numeric id
        "123456789 AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw",  # space instead of colon
    ],
)
def test_malformed_bot_tokens_are_rejected_before_any_network_call(token: str) -> None:
    assert not looks_like_bot_token(token)


def test_surrounding_whitespace_is_tolerated() -> None:
    """Users paste from BotFather, and the paste often carries a newline."""
    assert looks_like_bot_token("  123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw\n")


def test_api_urls_are_built_correctly() -> None:
    url = TelegramStorage._api_url("TOKEN", "sendDocument")
    assert url == "https://api.telegram.org/botTOKEN/sendDocument"
    assert TelegramStorage._file_url("TOKEN", "documents/file_1.pdf") == (
        "https://api.telegram.org/file/botTOKEN/documents/file_1.pdf"
    )
