"""Shared FastAPI dependencies: authentication, pagination, request context."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Annotated

import structlog
from fastapi import Depends, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.db import get_session
from app.core.errors import InvalidTokenError
from app.core.logging import hashed_user_id
from app.core.middleware import client_ip
from app.core.security import decode_access_token
from app.models import User
from app.services.token_blacklist import blacklist

# auto_error=False so a missing header raises our own envelope-shaped 401
# instead of Starlette's bare {"detail": ...}.
bearer_scheme = HTTPBearer(auto_error=False, scheme_name="Bearer")

SessionDep = Annotated[AsyncSession, Depends(get_session)]


@dataclass(frozen=True)
class RequestContext:
    """Client attribution for audit rows and session records."""

    ip_address: str | None
    user_agent: str | None


def get_request_context(request: Request) -> RequestContext:
    return RequestContext(
        ip_address=client_ip(request),
        user_agent=request.headers.get("user-agent"),
    )


ContextDep = Annotated[RequestContext, Depends(get_request_context)]


async def get_current_user(
    session: SessionDep,
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
) -> User:
    """Resolve the bearer token to a live user.

    Every authorisation decision in the API starts here: the ``user_id`` used by
    downstream queries comes from the signed token, never from the request body
    or path (cross-cutting rule 1).
    """
    if credentials is None or not credentials.credentials:
        raise InvalidTokenError("An Authorization: Bearer header is required")

    claims = decode_access_token(credentials.credentials)

    jti = claims.get("jti", "")
    if jti and await blacklist.is_revoked(jti):
        raise InvalidTokenError("This token has been revoked")

    try:
        user_id = uuid.UUID(claims["sub"])
    except (KeyError, ValueError) as exc:
        raise InvalidTokenError("The token subject is malformed") from exc

    user = await session.get(User, user_id)
    if user is None or not user.is_active:
        raise InvalidTokenError("The account no longer exists or is disabled")

    structlog.contextvars.bind_contextvars(user=hashed_user_id(user.id))
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


@dataclass(frozen=True)
class AccessTokenClaims:
    jti: str
    expires_at: datetime


async def get_access_token_claims(
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
) -> AccessTokenClaims | None:
    """Claims of the presented access token, for logout's blacklist write."""
    if credentials is None or not credentials.credentials:
        return None
    try:
        claims = decode_access_token(credentials.credentials)
    except InvalidTokenError:
        return None
    return AccessTokenClaims(
        jti=str(claims.get("jti", "")),
        expires_at=datetime.fromtimestamp(int(claims["exp"]), tz=UTC),
    )


@dataclass(frozen=True)
class Pagination:
    limit: int
    offset: int

    @property
    def page(self) -> int:
        return (self.offset // self.limit) + 1


def get_pagination(
    page: Annotated[int, Query(ge=1, description="1-indexed page number")] = 1,
    limit: Annotated[int | None, Query(ge=1, le=500)] = None,
    offset: Annotated[
        int | None,
        Query(ge=0, description="Row offset; overrides `page` when supplied"),
    ] = None,
) -> Pagination:
    """Accept either `page` or `offset`, and clamp the page size.

    The mobile client pages with `page`; the search screen's infinite scroll uses
    `offset`. Supporting both avoids a second pagination convention.
    """
    effective_limit = min(limit or settings.default_page_size, settings.max_page_size)
    effective_offset = offset if offset is not None else (page - 1) * effective_limit
    return Pagination(limit=effective_limit, offset=effective_offset)


PaginationDep = Annotated[Pagination, Depends(get_pagination)]
