"""Authentication endpoints (spec §2)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, status

from app.api.deps import (
    AccessTokenClaims,
    ContextDep,
    CurrentUser,
    SessionDep,
    get_access_token_claims,
)
from app.core.envelope import Ack, Envelope, ok
from app.core.errors import EmailAlreadyRegisteredError
from app.core.ratelimit import LOGIN_LIMIT, REGISTER_LIMIT, limiter
from app.models import ActivityAction
from app.schemas.auth import (
    GitHubAuthIn,
    GoogleAuthIn,
    LoginIn,
    RefreshIn,
    RegisterIn,
    SessionOut,
    TokenPair,
    UserOut,
)
from app.services import activity, oauth
from app.services import auth as auth_service
from app.services.token_blacklist import blacklist

router = APIRouter(prefix="/auth", tags=["auth"])


def _pair(issued: auth_service.IssuedSession) -> TokenPair:
    return TokenPair(
        access_token=issued.access_token,
        refresh_token=issued.refresh_token,
        expires_in=issued.expires_in,
    )


@router.post(
    "/register",
    response_model=Envelope[TokenPair],
    status_code=status.HTTP_201_CREATED,
    summary="Create an account",
)
async def register(
    payload: RegisterIn, session: SessionDep, ctx: ContextDep
) -> Envelope[TokenPair]:
    # Keyed by IP: the email is attacker-chosen, so limiting on it would let one
    # host register unlimited accounts by varying the address.
    await limiter.hit("register", ctx.ip_address or "unknown", REGISTER_LIMIT)

    if await auth_service.get_user_by_email(session, payload.email):
        raise EmailAlreadyRegisteredError()

    user = await auth_service.register(
        session,
        email=payload.email,
        password=payload.password,
        display_name=payload.display_name,
    )
    issued = await auth_service.issue_session(
        session, user, user_agent=ctx.user_agent, ip_address=ctx.ip_address
    )
    await activity.record(
        session,
        action=ActivityAction.LOGIN,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"method": "register"},
    )
    return ok(_pair(issued))


@router.post("/login", response_model=Envelope[TokenPair], summary="Sign in")
async def login(
    payload: LoginIn, session: SessionDep, ctx: ContextDep
) -> Envelope[TokenPair]:
    # Two counters: one stops a single host spraying many accounts, the other
    # stops a distributed attack concentrating on one account.
    identity = payload.email.strip().lower()
    await limiter.hit("login:ip", ctx.ip_address or "unknown", LOGIN_LIMIT)
    await limiter.hit("login:email", identity, LOGIN_LIMIT)

    user = await auth_service.authenticate(
        session, email=payload.email, password=payload.password
    )

    # A successful login clears the per-account counter so a user who mistyped a
    # few times is not locked out for the rest of the window.
    await limiter.reset("login:email", identity)

    issued = await auth_service.issue_session(
        session, user, user_agent=ctx.user_agent, ip_address=ctx.ip_address
    )
    await activity.record(
        session,
        action=ActivityAction.LOGIN,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"method": "password"},
    )
    return ok(_pair(issued))


@router.post("/google", response_model=Envelope[TokenPair], summary="Sign in with Google")
async def google_login(
    payload: GoogleAuthIn, session: SessionDep, ctx: ContextDep
) -> Envelope[TokenPair]:
    await limiter.hit("login:ip", ctx.ip_address or "unknown", LOGIN_LIMIT)
    identity = await oauth.verify_google_id_token(payload.id_token)
    user = await auth_service.upsert_oauth_user(
        session,
        provider=identity.provider,
        provider_user_id=identity.provider_user_id,
        email=identity.email,
        display_name=identity.display_name,
    )
    issued = await auth_service.issue_session(
        session, user, user_agent=ctx.user_agent, ip_address=ctx.ip_address
    )
    await activity.record(
        session,
        action=ActivityAction.LOGIN,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"method": "google"},
    )
    return ok(_pair(issued))


@router.post("/github", response_model=Envelope[TokenPair], summary="Sign in with GitHub")
async def github_login(
    payload: GitHubAuthIn, session: SessionDep, ctx: ContextDep
) -> Envelope[TokenPair]:
    await limiter.hit("login:ip", ctx.ip_address or "unknown", LOGIN_LIMIT)
    identity = await oauth.exchange_github_code(payload.code, payload.redirect_uri)
    user = await auth_service.upsert_oauth_user(
        session,
        provider=identity.provider,
        provider_user_id=identity.provider_user_id,
        email=identity.email,
        display_name=identity.display_name,
    )
    issued = await auth_service.issue_session(
        session, user, user_agent=ctx.user_agent, ip_address=ctx.ip_address
    )
    await activity.record(
        session,
        action=ActivityAction.LOGIN,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"method": "github"},
    )
    return ok(_pair(issued))


@router.post(
    "/refresh",
    response_model=Envelope[TokenPair],
    summary="Exchange a refresh token for a new pair",
)
async def refresh(
    payload: RefreshIn, session: SessionDep, ctx: ContextDep
) -> Envelope[TokenPair]:
    """Rotating refresh: the presented token is consumed and a new one returned.

    Replaying an already-consumed token revokes every session descended from the
    same login and returns `TOKEN_REUSE_DETECTED`.
    """
    issued = await auth_service.rotate_refresh_token(
        session,
        payload.refresh_token,
        user_agent=ctx.user_agent,
        ip_address=ctx.ip_address,
    )
    return ok(_pair(issued))


@router.post("/logout", response_model=Envelope[Ack], summary="Sign out")
async def logout(
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
    claims: Annotated[AccessTokenClaims | None, Depends(get_access_token_claims)] = None,
    payload: RefreshIn | None = None,
) -> Envelope[Ack]:
    """Revoke the current session.

    The refresh token dies immediately. The access token is self-contained, so it
    can only be blocked when Redis is configured — otherwise it stays valid for
    up to its remaining 15 minutes.
    """
    if payload is not None:
        await auth_service.revoke_refresh_token(session, payload.refresh_token)
    if claims is not None and claims.jti:
        await blacklist.revoke(claims.jti, claims.expires_at)

    await activity.record(
        session,
        action=ActivityAction.LOGOUT,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
    )
    return ok(Ack())


@router.post(
    "/logout-all",
    response_model=Envelope[Ack],
    summary="Revoke every session for this account",
)
async def logout_all(session: SessionDep, user: CurrentUser) -> Envelope[Ack]:
    revoked = await auth_service.revoke_all_sessions(session, user.id)
    return ok(Ack(ok=revoked >= 0))


@router.get("/me", response_model=Envelope[UserOut], summary="Current account")
async def me(user: CurrentUser) -> Envelope[UserOut]:
    return ok(UserOut.from_user(user))


@router.get(
    "/sessions",
    response_model=Envelope[list[SessionOut]],
    summary="List active sessions",
)
async def sessions(session: SessionDep, user: CurrentUser) -> Envelope[list[SessionOut]]:
    rows = await auth_service.list_sessions(session, user.id)
    return ok([SessionOut.model_validate(row) for row in rows])
