"""FastAPI application factory."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.api.router import api_router
from app.api.routes import health
from app.core.config import settings
from app.core.db import dispose_engine
from app.core.exception_handlers import register_exception_handlers
from app.core.logging import configure_logging, get_logger
from app.core.middleware import RequestContextMiddleware
from app.core.ratelimit import limiter

# Configure before anything else logs: modules that emit at import time (the
# rate limiter, for one) would otherwise cache a logger bound to the default
# configuration.
configure_logging()

log = get_logger(__name__)

DESCRIPTION = """
Metadata API for **Nimbus Drive** — personal cloud storage backed by your own
Telegram channel.

This service stores *metadata only*. File bytes live in the user's private
Telegram channel and are never persisted here; large uploads are streamed
through a temporary file that is deleted in a `finally` block.

Every response uses the same envelope:

```json
{ "success": true, "data": { }, "meta": { "page": 1, "limit": 50, "total": 247 } }
```
"""


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    configure_logging()

    # Staging area for chunked uploads. Created eagerly so a misconfigured path
    # fails at boot rather than half-way through a 500 MB upload.
    Path(settings.temp_dir).mkdir(parents=True, exist_ok=True)

    # Touch the keypair during startup so a bad key is a boot failure, not a
    # surprise on the first login.
    from app.core.security import keypair

    keypair()

    log.info(
        "startup",
        version=__version__,
        environment=settings.app_env,
        mtproto_configured=settings.mtproto_configured,
        redis=bool(settings.redis_url),
    )
    try:
        yield
    finally:
        from app.services.telegram_sessions import session_pool

        await session_pool.close_all()
        await limiter.close()
        await dispose_engine()
        log.info("shutdown")


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.project_name,
        description=DESCRIPTION,
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
    )

    app.add_middleware(RequestContextMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=["X-Request-ID", "Content-Range", "Accept-Ranges"],
    )

    register_exception_handlers(app)

    app.include_router(health.router)
    app.include_router(api_router, prefix=settings.api_prefix)
    return app


app = create_app()
