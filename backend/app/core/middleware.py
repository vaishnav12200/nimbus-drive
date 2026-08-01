"""Request-scoped logging context and the access log."""

from __future__ import annotations

import time
import uuid

import structlog
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import Response

from app.core.logging import get_logger

log = get_logger("http")

REQUEST_ID_HEADER = "X-Request-ID"


def client_ip(request: Request) -> str | None:
    """Best-effort client address, honouring one layer of reverse proxy.

    Only trust ``X-Forwarded-For`` when the app actually sits behind a proxy you
    control — see docs/SETUP.md for the Caddy/Nginx configuration this assumes.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    real_ip = request.headers.get("x-real-ip")
    if real_ip:
        return real_ip.strip()
    return request.client.host if request.client else None


class RequestContextMiddleware(BaseHTTPMiddleware):
    """Bind a request id to the structlog contextvars for the whole request."""

    async def dispatch(
        self, request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        request_id = request.headers.get(REQUEST_ID_HEADER) or str(uuid.uuid4())
        structlog.contextvars.clear_contextvars()
        structlog.contextvars.bind_contextvars(
            request_id=request_id,
            method=request.method,
            path=request.url.path,
        )
        request.state.request_id = request_id

        started = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            duration_ms = round((time.perf_counter() - started) * 1000, 2)
            log.exception("request_failed", duration_ms=duration_ms)
            raise

        duration_ms = round((time.perf_counter() - started) * 1000, 2)
        response.headers[REQUEST_ID_HEADER] = request_id

        # Health checks fire constantly; logging them at info level is noise.
        level = log.debug if request.url.path.endswith("/health") else log.info
        level(
            "request",
            status_code=response.status_code,
            duration_ms=duration_ms,
        )
        return response
