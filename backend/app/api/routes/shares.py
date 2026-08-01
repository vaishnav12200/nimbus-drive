"""Share link endpoints.

The two `/{token}` routes are the only unauthenticated surface in the API, so
they are rate limited and give away as little as possible: a bad token and a
revoked token are indistinguishable, and neither reveals whether the underlying
file exists.
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Header, Query, Request, status
from fastapi.responses import StreamingResponse

from app.api.deps import ContextDep, CurrentUser, SessionDep
from app.core.envelope import Ack, Envelope, ok
from app.core.errors import BadRequestError
from app.core.ratelimit import SHARE_PUBLIC_LIMIT, limiter
from app.models import ActivityAction
from app.schemas.share import PublicShareOut, ShareCreate, ShareOut
from app.services import (
    activity,
    downloads,
    telegram_config,
)
from app.services import (
    files as file_service,
)
from app.services import (
    shares as share_service,
)

router = APIRouter(prefix="/shares", tags=["shares"])


def _out(share: object, file: object | None = None) -> ShareOut:
    return ShareOut(
        id=share.id,  # type: ignore[attr-defined]
        file_id=share.file_id,  # type: ignore[attr-defined]
        token=share.token,  # type: ignore[attr-defined]
        expires_at=share.expires_at,  # type: ignore[attr-defined]
        max_downloads=share.max_downloads,  # type: ignore[attr-defined]
        download_count=share.download_count,  # type: ignore[attr-defined]
        requires_password=share.password_hash is not None,  # type: ignore[attr-defined]
        revoked_at=share.revoked_at,  # type: ignore[attr-defined]
        created_at=share.created_at,  # type: ignore[attr-defined]
        file_name=getattr(file, "name", None),
        file_size=getattr(file, "size", None),
    )


# --- Owner-facing ------------------------------------------------------


@router.post(
    "",
    response_model=Envelope[ShareOut],
    status_code=status.HTTP_201_CREATED,
    summary="Create a share link",
)
async def create_share(
    payload: ShareCreate, session: SessionDep, user: CurrentUser, ctx: ContextDep
) -> Envelope[ShareOut]:
    """Mint a public link for one file.

    Encrypted files are refused — see `app.services.shares` for why.
    """
    file = await file_service.get_file(
        session, user.id, payload.file_id, include_deleted=False
    )
    share = await share_service.create_share(
        session,
        user.id,
        file,
        expires_in=payload.expires_in,
        max_downloads=payload.max_downloads,
        password=payload.password,
    )
    await activity.record(
        session,
        action=ActivityAction.SHARE_CREATE,
        user_id=user.id,
        file_id=file.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"has_password": bool(payload.password)},
    )
    return ok(_out(share, file))


@router.get("", response_model=Envelope[list[ShareOut]], summary="List your links")
async def list_shares(session: SessionDep, user: CurrentUser) -> Envelope[list[ShareOut]]:
    rows = await share_service.list_shares(session, user.id)
    return ok([_out(share, file) for share, file in rows])


@router.delete("/{share_id}", response_model=Envelope[Ack], summary="Revoke a link")
async def revoke_share(
    share_id: uuid.UUID, session: SessionDep, user: CurrentUser, ctx: ContextDep
) -> Envelope[Ack]:
    share = await share_service.get_owned_share(session, user.id, share_id)
    await share_service.revoke(session, share)
    await activity.record(
        session,
        action=ActivityAction.SHARE_REVOKE,
        user_id=user.id,
        file_id=share.file_id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
    )
    return ok(Ack())


# --- Public ------------------------------------------------------------


@router.get(
    "/{token}",
    response_model=Envelope[PublicShareOut],
    summary="Public link metadata",
)
async def public_share(
    token: str, session: SessionDep, ctx: ContextDep
) -> Envelope[PublicShareOut]:
    """Describe a shared file to an unauthenticated visitor.

    Rate limited by IP so the token space cannot be swept for valid links.
    """
    await limiter.hit("share:meta", ctx.ip_address or "unknown", SHARE_PUBLIC_LIMIT)
    share, file = await share_service.resolve_token(session, token)
    return ok(
        PublicShareOut(
            name=file.name,
            size=file.size,
            mime_type=file.mime_type,
            is_encrypted=file.is_encrypted,
            requires_password=share.password_hash is not None,
            expires_at=share.expires_at,
            downloads_remaining=share_service.downloads_remaining(share),
        )
    )


@router.get("/{token}/download", summary="Public download")
async def public_download(
    token: str,
    request: Request,
    session: SessionDep,
    ctx: ContextDep,
    x_share_password: Annotated[str | None, Header()] = None,
    password: Annotated[
        str | None, Query(description="Prefer the X-Share-Password header")
    ] = None,
) -> StreamingResponse:
    """Stream a shared file to an unauthenticated visitor.

    The password may be sent as `X-Share-Password` or `?password=`; the header is
    preferred because query strings end up in proxy logs and `Referer` headers.
    The quota is claimed atomically *before* streaming starts.
    """
    await limiter.hit("share:download", ctx.ip_address or "unknown", SHARE_PUBLIC_LIMIT)

    share, file = await share_service.resolve_token(session, token)
    share_service.check_password(share, x_share_password or password)

    if file.telegram_channel_id is None or (
        file.telegram_message_id is None and not file.is_chunked
    ):
        raise BadRequestError(
            "The shared file has no stored bytes", code="FILE_NOT_UPLOADED"
        )

    await share_service.consume_download(session, share)

    # The owner's credentials, not the visitor's — the visitor has no Telegram
    # relationship with this channel at all.
    credentials = await telegram_config.get_credentials(session, share.user_id)

    byte_range = downloads.parse_range(request.headers.get("range"), file.size)
    plan = downloads.build_plan(file, byte_range)

    await activity.record(
        session,
        action=ActivityAction.SHARE_DOWNLOAD,
        user_id=share.user_id,
        file_id=file.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"share_id": str(share.id)},
    )

    headers = {
        "Content-Disposition": downloads.content_disposition(file.name),
        "Accept-Ranges": "bytes",
        "Content-Length": str(plan.length),
        "Cache-Control": "private, no-store",
        # A share link is a capability URL; keep it out of the next site's logs.
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
    }
    status_code = 200
    if byte_range.partial:
        headers["Content-Range"] = downloads.content_range_header(plan)
        status_code = 206

    return StreamingResponse(
        downloads.stream(plan, credentials),
        status_code=status_code,
        media_type=file.mime_type or "application/octet-stream",
        headers=headers,
    )
