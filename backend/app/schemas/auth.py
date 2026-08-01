"""Request/response schemas for the auth endpoints."""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

# Long enough to resist online guessing given the login rate limit, short enough
# that Argon2 is not handed a megabyte of "password".
MIN_PASSWORD_LENGTH = 8
MAX_PASSWORD_LENGTH = 256


class _PasswordMixin(BaseModel):
    password: str = Field(
        ...,
        min_length=MIN_PASSWORD_LENGTH,
        max_length=MAX_PASSWORD_LENGTH,
        examples=["correct-horse-battery-staple"],
    )

    @field_validator("password")
    @classmethod
    def _reject_whitespace_only(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("password must not be only whitespace")
        return v


class RegisterIn(_PasswordMixin):
    email: EmailStr
    display_name: str | None = Field(default=None, max_length=120)


class LoginIn(_PasswordMixin):
    email: EmailStr


class RefreshIn(BaseModel):
    refresh_token: str = Field(..., min_length=16, max_length=512)


class GoogleAuthIn(BaseModel):
    id_token: str = Field(..., min_length=16)


class GitHubAuthIn(BaseModel):
    code: str = Field(..., min_length=1)
    redirect_uri: str | None = None


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int = Field(..., description="Access token lifetime in seconds")


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: EmailStr
    display_name: str | None
    encryption_enabled: bool
    has_password: bool
    linked_providers: list[str]
    created_at: datetime
    last_login_at: datetime | None

    @classmethod
    def from_user(cls, user: object) -> UserOut:
        providers = []
        if getattr(user, "google_id", None):
            providers.append("google")
        if getattr(user, "github_id", None):
            providers.append("github")
        return cls(
            id=user.id,  # type: ignore[attr-defined]
            email=user.email,  # type: ignore[attr-defined]
            display_name=user.display_name,  # type: ignore[attr-defined]
            encryption_enabled=user.encryption_enabled,  # type: ignore[attr-defined]
            has_password=bool(getattr(user, "password_hash", None)),
            linked_providers=providers,
            created_at=user.created_at,  # type: ignore[attr-defined]
            last_login_at=user.last_login_at,  # type: ignore[attr-defined]
        )


class SessionOut(BaseModel):
    """A live refresh-token session, for a 'signed in devices' screen."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    issued_at: datetime
    expires_at: datetime
    user_agent: str | None
    ip_address: str | None
    current: bool = False

    @field_validator("ip_address", mode="before")
    @classmethod
    def _stringify_inet(cls, v: object) -> object:
        # asyncpg hydrates PostgreSQL INET columns as ipaddress objects.
        return str(v) if v is not None and not isinstance(v, str) else v
