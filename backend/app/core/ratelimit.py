"""Fixed-window rate limiting.

The spec has no rate limits at all, which leaves `/api/auth/login` open to
credential stuffing and the public share endpoints open to token enumeration.
This closes both.

Backed by Redis when ``REDIS_URL`` is set (correct across replicas) and by an
in-process dict otherwise (good enough for a single self-hosted container). The
in-process path is deliberately not shared between workers — it is a floor, not a
guarantee.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from app.core.config import settings
from app.core.errors import RateLimitedError
from app.core.logging import get_logger

log = get_logger(__name__)


@dataclass(frozen=True)
class Limit:
    count: int
    window_seconds: int

    @classmethod
    def parse(cls, spec: str) -> Limit:
        """Parse ``"10/300"`` — ten requests per 300 seconds."""
        count, _, window = spec.partition("/")
        return cls(count=int(count), window_seconds=int(window))


class _MemoryBackend:
    def __init__(self) -> None:
        self._hits: dict[str, tuple[int, float]] = {}

    async def incr(self, key: str, window: int) -> tuple[int, int]:
        now = time.monotonic()
        count, reset_at = self._hits.get(key, (0, 0.0))
        if now >= reset_at:
            count, reset_at = 0, now + window
        count += 1
        self._hits[key] = (count, reset_at)
        if len(self._hits) > 10_000:  # bound memory on a long-lived process
            self._evict(now)
        return count, max(1, int(reset_at - now))

    def _evict(self, now: float) -> None:
        for key in [k for k, (_, reset) in self._hits.items() if reset <= now]:
            self._hits.pop(key, None)

    async def reset(self, key: str) -> None:
        self._hits.pop(key, None)

    async def clear(self) -> None:
        self._hits.clear()


class _RedisBackend:
    def __init__(self, url: str) -> None:
        import redis.asyncio as redis

        self._redis = redis.from_url(url, decode_responses=True)

    async def incr(self, key: str, window: int) -> tuple[int, int]:
        pipe = self._redis.pipeline()
        pipe.incr(key)
        pipe.ttl(key)
        count, ttl = await pipe.execute()
        if ttl < 0:  # key had no expiry yet — this is the first hit in the window
            await self._redis.expire(key, window)
            ttl = window
        return int(count), int(ttl)

    async def reset(self, key: str) -> None:
        await self._redis.delete(key)

    async def close(self) -> None:
        await self._redis.aclose()


class RateLimiter:
    def __init__(self) -> None:
        self._backend: _MemoryBackend | _RedisBackend
        if settings.redis_url:
            self._backend = _RedisBackend(settings.redis_url)
            log.info("ratelimit_backend", backend="redis")
        else:
            self._backend = _MemoryBackend()
            log.info("ratelimit_backend", backend="memory")

    async def hit(self, scope: str, identity: str, limit: Limit) -> None:
        """Count one request; raise :class:`RateLimitedError` once over the limit."""
        key = f"nimbus:rl:{scope}:{identity}"
        count, retry_after = await self._backend.incr(key, limit.window_seconds)
        if count > limit.count:
            log.warning("rate_limited", scope=scope, retry_after=retry_after)
            raise RateLimitedError(retry_after=retry_after)

    async def reset(self, scope: str, identity: str) -> None:
        """Clear a counter — used after a successful login so one bad password
        does not count against a legitimate user for the rest of the window."""
        await self._backend.reset(f"nimbus:rl:{scope}:{identity}")

    async def clear_all(self) -> None:
        """Drop every counter. Only for tests and manual operator intervention —
        the in-memory backend is process-local, so this is not a cluster-wide
        reset."""
        if isinstance(self._backend, _MemoryBackend):
            await self._backend.clear()

    async def close(self) -> None:
        if isinstance(self._backend, _RedisBackend):
            await self._backend.close()


limiter = RateLimiter()

LOGIN_LIMIT = Limit.parse(settings.rate_limit_login)
REGISTER_LIMIT = Limit.parse(settings.rate_limit_register)
SHARE_PUBLIC_LIMIT = Limit.parse(settings.rate_limit_share_public)
