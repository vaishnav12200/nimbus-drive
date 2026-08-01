"""Optional access-token revocation via a Redis `jti` blacklist.

Access tokens are self-contained and live 15 minutes, so logging out cannot
"unissue" one. When Redis is configured, logout parks the token's `jti` until its
natural expiry and every authenticated request checks that set.

Without Redis this degrades to a no-op: the refresh token is still revoked, so
the session dies within one access-token lifetime. That trade-off is the reason
the spec calls this optional.
"""

from __future__ import annotations

from datetime import UTC, datetime

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)

_KEY_PREFIX = "nimbus:jti:"


class TokenBlacklist:
    def __init__(self) -> None:
        self._client = None
        self._enabled = bool(settings.redis_url)

    def _get_client(self):  # type: ignore[no-untyped-def]
        if self._client is None and self._enabled:
            import redis.asyncio as redis

            self._client = redis.from_url(settings.redis_url or "")
        return self._client

    @property
    def enabled(self) -> bool:
        return self._enabled

    async def revoke(self, jti: str, expires_at: datetime) -> None:
        client = self._get_client()
        if client is None:
            return
        ttl = int((expires_at - datetime.now(UTC)).total_seconds())
        if ttl <= 0:
            return  # already expired; nothing to block
        try:
            await client.setex(f"{_KEY_PREFIX}{jti}", ttl, "1")
        except Exception as exc:  # pragma: no cover - Redis is best-effort
            log.warning("token_blacklist_write_failed", exc_info=exc)

    async def is_revoked(self, jti: str) -> bool:
        client = self._get_client()
        if client is None:
            return False
        try:
            return bool(await client.exists(f"{_KEY_PREFIX}{jti}"))
        except Exception as exc:  # pragma: no cover - fail open, log loudly
            # Failing closed would take the whole API down with Redis, which is
            # a worse outcome than a revoked token surviving for <15 minutes.
            log.warning("token_blacklist_read_failed", exc_info=exc)
            return False

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None


blacklist = TokenBlacklist()
