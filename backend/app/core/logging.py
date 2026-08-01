"""structlog configuration.

Two rules from the spec are enforced here rather than left to call sites:

* **Secrets never reach a log sink.** `_redact_secrets` scrubs any event key that
  looks like a credential, whatever the caller passed (cross-cutting rule 3).
* **User identifiers are hashed.** `hashed_user_id` produces the short digest that
  should be bound to the request context instead of a raw UUID (privacy section).
"""

from __future__ import annotations

import hashlib
import logging
import sys
from typing import Any

import structlog
from structlog.types import EventDict, Processor

from app.core.config import settings

SENSITIVE_KEYS = frozenset(
    {
        "authorization",
        "bot_token",
        "password",
        "password_hash",
        "new_password",
        "token",
        "access_token",
        "refresh_token",
        "id_token",
        "client_secret",
        "secret",
        "secret_encryption_key",
        "jwt_private_key",
        "encryption_key",
        "api_hash",
        "telegram_api_hash",
    }
)

REDACTED = "[redacted]"


def _redact_secrets(_: Any, __: str, event_dict: EventDict) -> EventDict:
    for key in list(event_dict):
        if key.lower() in SENSITIVE_KEYS:
            event_dict[key] = REDACTED
    return event_dict


def hashed_user_id(user_id: object) -> str:
    """Short, stable, non-reversible identifier safe to put in logs."""
    return hashlib.sha256(str(user_id).encode()).hexdigest()[:16]


_configured = False


def configure_logging(force: bool = False) -> None:
    """Idempotently route structlog and the stdlib logging tree to one handler.

    Everything goes through the stdlib logger factory rather than structlog's own
    printer, so uvicorn's and SQLAlchemy's records land in the same formatter as
    ours and the output stays one consistent stream.
    """
    global _configured
    if _configured and not force:
        return

    level = logging.DEBUG if settings.debug else logging.INFO

    shared: list[Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.UnicodeDecoder(),
        _redact_secrets,
    ]

    renderer: Processor = (
        structlog.processors.JSONRenderer()
        if settings.is_production
        else structlog.dev.ConsoleRenderer(colors=sys.stderr.isatty())
    )

    structlog.configure(
        processors=[
            *shared,
            # Hands the event dict to the stdlib handler's ProcessorFormatter
            # below, which does the actual rendering.
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        wrapper_class=structlog.stdlib.BoundLogger,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        structlog.stdlib.ProcessorFormatter(
            # `foreign_pre_chain` is applied to records from libraries that log
            # through plain stdlib logging and never touched structlog.
            foreign_pre_chain=shared,
            processors=[
                structlog.stdlib.ProcessorFormatter.remove_processors_meta,
                renderer,
            ],
        )
    )
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    for noisy in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logging.getLogger(noisy).handlers = []
        logging.getLogger(noisy).propagate = True

    logging.getLogger("telethon").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)

    _configured = True


def get_logger(name: str | None = None) -> structlog.stdlib.BoundLogger:
    return structlog.get_logger(name)  # type: ignore[no-any-return]
