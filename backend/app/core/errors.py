"""Application error types and the uniform error envelope.

Every failure leaves the API as:

    {"success": false,
     "error": {"code": "FILE_NOT_FOUND", "message": "...", "details": {...}}}

Clients switch on ``error.code`` — never on the message (cross-cutting rule 7).
"""

from __future__ import annotations

from typing import Any


class AppError(Exception):
    """Base class for every error that maps onto the spec's error envelope."""

    status_code: int = 500
    code: str = "INTERNAL_ERROR"
    message: str = "An unexpected error occurred"

    def __init__(
        self,
        message: str | None = None,
        *,
        code: str | None = None,
        details: dict[str, Any] | None = None,
        status_code: int | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.message = message or self.message
        self.code = code or self.code
        self.details = details or {}
        self.status_code = status_code or self.status_code
        self.headers = headers or {}
        super().__init__(self.message)

    def to_envelope(self) -> dict[str, Any]:
        error: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details:
            error["details"] = self.details
        return {"success": False, "error": error}


# --- 400 ---------------------------------------------------------------


class BadRequestError(AppError):
    status_code = 400
    code = "BAD_REQUEST"
    message = "The request was malformed"


class ValidationError(AppError):
    status_code = 422
    code = "VALIDATION_ERROR"
    message = "The request failed validation"


# --- 401 / 403 ---------------------------------------------------------


class AuthenticationError(AppError):
    status_code = 401
    code = "UNAUTHENTICATED"
    message = "Authentication is required"

    def __init__(self, message: str | None = None, **kwargs: Any) -> None:
        kwargs.setdefault("headers", {"WWW-Authenticate": "Bearer"})
        super().__init__(message, **kwargs)


class InvalidCredentialsError(AuthenticationError):
    code = "INVALID_CREDENTIALS"
    message = "Incorrect email or password"


class InvalidTokenError(AuthenticationError):
    code = "INVALID_TOKEN"
    message = "The token is invalid or has expired"


class TokenReuseError(AuthenticationError):
    code = "TOKEN_REUSE_DETECTED"
    message = "Refresh token reuse detected; the session family has been revoked"


class PermissionDeniedError(AppError):
    status_code = 403
    code = "PERMISSION_DENIED"
    message = "You do not have access to this resource"


# --- 404 ---------------------------------------------------------------


class NotFoundError(AppError):
    status_code = 404
    code = "NOT_FOUND"
    message = "The requested resource does not exist"


class FileMissingError(NotFoundError):
    # Not `FileNotFoundError`: that name is a builtin, and shadowing it inside
    # `except` blocks would silently change which errors get caught.
    code = "FILE_NOT_FOUND"
    message = "The requested file does not exist"


class FolderNotFoundError(NotFoundError):
    code = "FOLDER_NOT_FOUND"
    message = "The requested folder does not exist"


class ShareNotFoundError(NotFoundError):
    code = "SHARE_NOT_FOUND"
    message = "The share link does not exist or has been revoked"


class TelegramConfigMissingError(NotFoundError):
    code = "TELEGRAM_NOT_CONFIGURED"
    message = "No Telegram channel is bound to this account"


# --- 409 / 410 / 413 ---------------------------------------------------


class ConflictError(AppError):
    status_code = 409
    code = "CONFLICT"
    message = "The request conflicts with the current state"


class EmailAlreadyRegisteredError(ConflictError):
    code = "EMAIL_ALREADY_REGISTERED"
    message = "An account with this email already exists"


class FolderNotEmptyError(ConflictError):
    code = "FOLDER_NOT_EMPTY"
    message = "The folder is not empty; delete its contents or pass cascade=true"


class ShareExpiredError(AppError):
    status_code = 410
    code = "SHARE_EXPIRED"
    message = "This share link has expired or reached its download limit"


class PayloadTooLargeError(AppError):
    status_code = 413
    code = "FILE_TOO_LARGE"
    message = "The file exceeds the maximum supported size"


class RangeNotSatisfiableError(AppError):
    status_code = 416
    code = "RANGE_NOT_SATISFIABLE"
    message = "The requested byte range cannot be satisfied"


# --- 429 ---------------------------------------------------------------


class RateLimitedError(AppError):
    status_code = 429
    code = "RATE_LIMITED"
    message = "Too many requests; slow down"

    def __init__(self, retry_after: int, **kwargs: Any) -> None:
        kwargs.setdefault("headers", {"Retry-After": str(retry_after)})
        kwargs.setdefault("details", {"retry_after": retry_after})
        super().__init__(**kwargs)


# --- 5xx / upstream ----------------------------------------------------


class StorageError(AppError):
    status_code = 502
    code = "STORAGE_ERROR"
    message = "The storage backend rejected the request"


class TelegramError(StorageError):
    code = "TELEGRAM_ERROR"
    message = "Telegram rejected the request"


class TelegramFloodWaitError(TelegramError):
    status_code = 429
    code = "FLOOD_WAIT"
    message = "Telegram is rate limiting this bot"

    def __init__(self, seconds: int, **kwargs: Any) -> None:
        kwargs.setdefault("headers", {"Retry-After": str(seconds)})
        kwargs.setdefault("details", {"retry_after": seconds})
        super().__init__(**kwargs)


class ServiceUnavailableError(AppError):
    status_code = 503
    code = "SERVICE_UNAVAILABLE"
    message = "The service is temporarily unavailable"


class MTProtoUnavailableError(ServiceUnavailableError):
    code = "MTPROTO_UNAVAILABLE"
    message = (
        "Large-file support requires TELEGRAM_API_ID and TELEGRAM_API_HASH "
        "to be configured on the backend"
    )
