"""Pooled Telethon (MTProto) clients, one per bot token.

Connecting to MTProto costs a handshake and an auth key exchange, so a client is
kept alive and reused across requests. The pool is keyed by a digest of the bot
token — the token itself is never used as a dict key, a log field, or a filename.

Sessions are held in memory (``StringSession``) rather than on disk. Telethon's
default is a SQLite ``*.session`` file containing a *live credential*; keeping it
out of the filesystem means a container image or a stray backup cannot leak one.
The cost is a fresh handshake after a restart, which is a few hundred
milliseconds once per bot.
"""

from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import dataclass, field

from app.core.config import settings
from app.core.errors import MTProtoUnavailableError, TelegramError
from app.core.logging import get_logger

log = get_logger(__name__)

# Drop a client that has not been used for this long; a self-hosted instance may
# go days between large uploads and idle TCP connections get reaped anyway.
IDLE_TIMEOUT_SECONDS = 15 * 60
MAX_CLIENTS = 32


def _token_key(bot_token: str) -> str:
    return hashlib.sha256(bot_token.encode()).hexdigest()[:32]


@dataclass
class _Entry:
    client: object
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    last_used: float = field(default_factory=time.monotonic)


class TelegramSessionPool:
    def __init__(self) -> None:
        self._entries: dict[str, _Entry] = {}
        self._guard = asyncio.Lock()

    async def acquire(self, bot_token: str):  # type: ignore[no-untyped-def]
        """Return a connected, authorised Telethon client for ``bot_token``."""
        if not settings.mtproto_configured:
            raise MTProtoUnavailableError()

        key = _token_key(bot_token)

        async with self._guard:
            await self._evict_idle()
            entry = self._entries.get(key)
            if entry is None:
                entry = _Entry(client=await self._connect(bot_token))
                self._entries[key] = entry
                if len(self._entries) > MAX_CLIENTS:
                    await self._evict_oldest()
            entry.last_used = time.monotonic()

        client = entry.client
        if not client.is_connected():  # type: ignore[attr-defined]
            # Reconnect in place so callers never see a dead client.
            await client.connect()  # type: ignore[attr-defined]
        return client

    async def _connect(self, bot_token: str):  # type: ignore[no-untyped-def]
        from telethon import TelegramClient
        from telethon.sessions import StringSession

        client = TelegramClient(
            StringSession(),
            settings.telegram_api_id,
            settings.telegram_api_hash,
            # A single connection keeps memory predictable when several users'
            # clients are alive at once; large uploads are chunk-sequential anyway.
            connection_retries=3,
            retry_delay=2,
            request_retries=3,
        )
        try:
            await client.start(bot_token=bot_token)  # type: ignore[misc]
        except Exception as exc:
            log.warning("mtproto_login_failed", error=type(exc).__name__)
            raise TelegramError(
                "Could not sign in to Telegram with this bot token",
                code="MTPROTO_LOGIN_FAILED",
            ) from exc
        log.info("mtproto_client_connected")
        return client

    async def _evict_idle(self) -> None:
        now = time.monotonic()
        stale = [
            key
            for key, entry in self._entries.items()
            if now - entry.last_used > IDLE_TIMEOUT_SECONDS and not entry.lock.locked()
        ]
        for key in stale:
            await self._disconnect(self._entries.pop(key))

    async def _evict_oldest(self) -> None:
        idle = [(k, e) for k, e in self._entries.items() if not e.lock.locked()]
        if not idle:
            return
        key, entry = min(idle, key=lambda kv: kv[1].last_used)
        self._entries.pop(key, None)
        await self._disconnect(entry)

    async def _disconnect(self, entry: _Entry) -> None:
        try:
            await entry.client.disconnect()  # type: ignore[attr-defined]
        except Exception as exc:  # pragma: no cover - teardown is best-effort
            log.debug("mtproto_disconnect_failed", exc_info=exc)

    async def close_all(self) -> None:
        async with self._guard:
            entries = list(self._entries.values())
            self._entries.clear()
        for entry in entries:
            await self._disconnect(entry)
        if entries:
            log.info("mtproto_clients_closed", count=len(entries))


session_pool = TelegramSessionPool()
