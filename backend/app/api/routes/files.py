"""File endpoints: metadata CRUD, large-file upload, download and streaming.

Route order matters here — static segments (`/trash/empty`, `/dedup`) are
declared before `/{file_id}`, otherwise FastAPI would match them as an id.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import APIRouter, Query, Request, status
from fastapi.responses import StreamingResponse
from starlette.datastructures import UploadFile as StarletteUploadFile

from app.api.deps import ContextDep, CurrentUser, PaginationDep, SessionDep
from app.core.config import settings
from app.core.envelope import Ack, Envelope, ok, page
from app.core.errors import (
    BadRequestError,
    ConflictError,
    PayloadTooLargeError,
    TelegramError,
)
from app.core.logging import get_logger
from app.models import ActivityAction, File
from app.models.enums import FileSort, SortOrder
from app.providers.base import StorageCredentials
from app.schemas.file import (
    DedupHit,
    DownloadTicket,
    FileCopy,
    FileCreate,
    FileDetailOut,
    FileOut,
    FileReserve,
    FileTarget,
    FileUpdate,
)
from app.services import (
    activity,
    downloads,
    encryption,
    telegram_config,
    uploads,
)
from app.services import (
    files as file_service,
)

log = get_logger(__name__)
router = APIRouter(prefix="/files", tags=["files"])

READ_CHUNK = 1024 * 1024


# --- Collection --------------------------------------------------------


@router.get("", response_model=Envelope[list[FileOut]], summary="List files")
async def list_files(
    session: SessionDep,
    user: CurrentUser,
    pagination: PaginationDep,
    folder_id: Annotated[uuid.UUID | None, Query()] = None,
    root: Annotated[bool, Query(description="List the root instead of a folder")] = False,
    trash: Annotated[bool, Query(description="List soft-deleted files")] = False,
    favorites: Annotated[bool, Query(description="Only favourites")] = False,
    sort: FileSort = FileSort.CREATED_AT,
    order: SortOrder = SortOrder.DESC,
) -> Envelope[list[FileOut]]:
    """Files in one folder, the root, the trash, or the favourites view.

    Favourites and trash are *virtual* folders — filters over the same table
    rather than real rows — so a favourite keeps its real location.
    """
    rows, total = await file_service.list_files(
        session,
        user.id,
        folder_id=folder_id,
        root_only=root and folder_id is None,
        is_deleted=trash,
        is_favorite=True if favorites else None,
        sort=sort,
        order=order,
        limit=pagination.limit,
        offset=pagination.offset,
    )
    return page(
        [FileOut.from_model(row) for row in rows],
        total=total,
        limit=pagination.limit,
        offset=pagination.offset,
    )


@router.get("/dedup", response_model=Envelope[DedupHit], summary="Check for a duplicate")
async def check_duplicate(
    session: SessionDep,
    user: CurrentUser,
    sha256: Annotated[str, Query(min_length=64, max_length=64)],
) -> Envelope[DedupHit]:
    """Ask whether these bytes are already stored, before spending an upload.

    The client hashes the *plaintext*, so this also catches a file it previously
    uploaded encrypted.
    """
    existing = await file_service.find_duplicate(session, user.id, sha256.lower())
    if existing is None:
        return ok(DedupHit(found=False))
    return ok(
        DedupHit(found=True, file_id=existing.id, name=existing.name, size=existing.size)
    )


@router.post(
    "",
    response_model=Envelope[FileOut],
    status_code=status.HTTP_201_CREATED,
    summary="Record a client-side upload",
)
async def create_file(
    payload: FileCreate, session: SessionDep, user: CurrentUser, ctx: ContextDep
) -> Envelope[FileOut]:
    """Register metadata for a file the client already sent to Telegram (≤ 20 MB).

    The channel id comes from the caller's own binding, never from the request —
    a client cannot file a row against someone else's channel.
    """
    config = await telegram_config.require_active_config(session, user.id)

    if payload.size > settings.telegram_bot_api_max_upload:
        raise BadRequestError(
            "Files over 20 MB must be uploaded through POST /api/files/{id}/upload",
            code="USE_BACKEND_UPLOAD",
            details={"limit": settings.telegram_bot_api_max_upload},
        )

    if payload.is_encrypted:
        # Recording a file as encrypted when no salt is stored would produce a
        # row nobody can ever decrypt on a second device.
        encryption.assert_can_store_encrypted(user)

    file = await file_service.create_file(
        session,
        user.id,
        name=payload.name,
        original_name=payload.original_name or payload.name,
        size=payload.size,
        mime_type=payload.mime_type,
        channel_id=config.channel_id,
        telegram_message_id=payload.telegram_message_id,
        telegram_file_id=payload.telegram_file_id,
        telegram_file_unique_id=payload.telegram_file_unique_id,
        sha256=payload.sha256,
        folder_id=payload.folder_id,
        is_encrypted=payload.is_encrypted,
        tags=payload.tags,
    )
    await activity.record(
        session,
        action=ActivityAction.UPLOAD,
        user_id=user.id,
        file_id=file.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"size": file.size, "path": "client"},
    )
    return ok(FileOut.from_model(file))


@router.post(
    "/reserve",
    response_model=Envelope[FileOut],
    status_code=status.HTTP_201_CREATED,
    summary="Reserve a row for a large upload",
)
async def reserve_file(
    payload: FileReserve, session: SessionDep, user: CurrentUser
) -> Envelope[FileOut]:
    """Create the metadata row *before* the bytes move.

    Large uploads are two requests so the client has a stable id to attach
    progress, pause/resume and retries to — a 500 MB upload that has to restart
    from "which file was that again?" is not resumable in any useful sense.
    """
    config = await telegram_config.require_active_config(session, user.id)

    if payload.size > settings.telegram_max_file_size:
        raise PayloadTooLargeError(
            "Telegram caps a single file at 2 GB. Split it before uploading.",
            details={"size": payload.size, "limit": settings.telegram_max_file_size},
        )

    if payload.is_encrypted:
        encryption.assert_can_store_encrypted(user)

    file = await file_service.create_file(
        session,
        user.id,
        name=payload.name,
        original_name=payload.name,
        size=payload.size,
        mime_type=payload.mime_type,
        channel_id=config.channel_id,
        sha256=payload.sha256,
        folder_id=payload.folder_id,
        is_encrypted=payload.is_encrypted,
        tags=payload.tags,
    )
    return ok(FileOut.from_model(file))


@router.post(
    "/trash/empty", response_model=Envelope[Ack], summary="Permanently empty the trash"
)
async def empty_trash(
    session: SessionDep, user: CurrentUser, ctx: ContextDep
) -> Envelope[Ack]:
    """Hard-delete every trashed file, including its Telegram messages."""
    credentials = await _credentials_or_none(session, user.id)
    trashed = await file_service.empty_trash(session, user.id)
    for file in trashed:
        await file_service.purge_file(session, file, credentials)
    await activity.record(
        session,
        action=ActivityAction.PURGE,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"count": len(trashed)},
    )
    return ok(Ack())


# --- Single file -------------------------------------------------------


@router.get("/{file_id}", response_model=Envelope[FileDetailOut], summary="Get a file")
async def get_file(
    file_id: uuid.UUID, session: SessionDep, user: CurrentUser
) -> Envelope[FileDetailOut]:
    file = await file_service.get_file(session, user.id, file_id)
    return ok(FileDetailOut.from_model(file))


@router.patch("/{file_id}", response_model=Envelope[FileOut], summary="Update a file")
async def update_file(
    file_id: uuid.UUID,
    payload: FileUpdate,
    request: Request,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
) -> Envelope[FileOut]:
    """Rename, move, favourite or retag.

    `folder_id: null` means *move to the root*, which is different from omitting
    the field; the raw body is inspected to tell the two apart.
    """
    file = await file_service.get_file(session, user.id, file_id)
    body = await _raw_json(request)

    file = await file_service.update_file(
        session,
        file,
        name=payload.name,
        folder_id=payload.folder_id,
        move="folder_id" in body,
        is_favorite=payload.is_favorite,
        tags=payload.tags,
    )

    if payload.is_favorite is not None:
        await activity.record(
            session,
            action=(
                ActivityAction.FAVORITE
                if payload.is_favorite
                else ActivityAction.UNFAVORITE
            ),
            user_id=user.id,
            file_id=file.id,
            ip_address=ctx.ip_address,
            user_agent=ctx.user_agent,
        )
    if payload.name is not None:
        await activity.record(
            session,
            action=ActivityAction.RENAME,
            user_id=user.id,
            file_id=file.id,
            ip_address=ctx.ip_address,
            user_agent=ctx.user_agent,
        )
    return ok(FileOut.from_model(file))


@router.delete("/{file_id}", response_model=Envelope[Ack], summary="Delete a file")
async def delete_file(
    file_id: uuid.UUID,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
    permanent: Annotated[
        bool, Query(description="Skip the trash and delete the Telegram bytes too")
    ] = False,
) -> Envelope[Ack]:
    """Soft delete by default (rule 4). `permanent=true` also removes the bytes.

    A permanent delete only removes the Telegram message when no other row —
    a copy, for instance — still points at it.
    """
    file = await file_service.get_file(session, user.id, file_id)

    if permanent:
        credentials = await _credentials_or_none(session, user.id)
        await file_service.purge_file(session, file, credentials)
        action = ActivityAction.PURGE
    else:
        await file_service.soft_delete(session, file)
        action = ActivityAction.DELETE

    await activity.record(
        session,
        action=action,
        user_id=user.id,
        file_id=None if permanent else file_id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"permanent": permanent},
    )
    return ok(Ack())


@router.post(
    "/{file_id}/restore", response_model=Envelope[FileOut], summary="Restore from trash"
)
async def restore_file(
    file_id: uuid.UUID, session: SessionDep, user: CurrentUser, ctx: ContextDep
) -> Envelope[FileOut]:
    file = await file_service.get_file(session, user.id, file_id)
    await file_service.restore(session, file)
    await activity.record(
        session,
        action=ActivityAction.RESTORE,
        user_id=user.id,
        file_id=file.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
    )
    return ok(FileOut.from_model(file))


@router.post("/{file_id}/move", response_model=Envelope[FileOut], summary="Move a file")
async def move_file(
    file_id: uuid.UUID,
    payload: FileTarget,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
) -> Envelope[FileOut]:
    file = await file_service.get_file(session, user.id, file_id)
    await file_service.move_file(session, file, payload.target_folder_id)
    await activity.record(
        session,
        action=ActivityAction.MOVE,
        user_id=user.id,
        file_id=file.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
    )
    return ok(FileOut.from_model(file))


@router.post("/{file_id}/copy", response_model=Envelope[FileOut], summary="Copy a file")
async def copy_file(
    file_id: uuid.UUID,
    payload: FileCopy,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
) -> Envelope[FileOut]:
    """Duplicate the metadata. The bytes are shared, not re-uploaded.

    Deleting either copy leaves the other working: the Telegram message is only
    removed once the last row referencing it is purged.
    """
    file = await file_service.get_file(session, user.id, file_id)
    copy = await file_service.copy_file(
        session, file, target_folder_id=payload.target_folder_id, name=payload.name
    )
    await activity.record(
        session,
        action=ActivityAction.COPY,
        user_id=user.id,
        file_id=copy.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"source_file_id": str(file.id)},
    )
    return ok(FileOut.from_model(copy))


# --- Bytes -------------------------------------------------------------


@router.post(
    "/{file_id}/upload",
    response_model=Envelope[FileDetailOut],
    summary="Upload the bytes of a reserved file",
)
async def upload_bytes(
    file_id: uuid.UUID,
    request: Request,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
) -> Envelope[FileDetailOut]:
    """Stream a file through the backend into Telegram.

    Accepts either `multipart/form-data` with a `file` part or a raw
    `application/octet-stream` body. Prefer the raw body for large uploads: the
    multipart parser spools the part to disk before we copy it, so it costs twice
    the staging space.

    The bytes are written to one temp file, hashed on the way past, split into
    19 MB segments and pushed over MTProto. The temp file is deleted whatever
    happens.
    """
    file = await file_service.get_file(session, user.id, file_id)

    if file.telegram_message_id is not None or file.is_chunked:
        raise ConflictError(
            "This file already has stored bytes. Reserve a new row instead.",
            code="ALREADY_UPLOADED",
        )

    credentials = await telegram_config.get_credentials(session, user.id)

    async with uploads.upload_slot():
        uploads.assert_disk_headroom(file.size)

        with uploads.staging_file() as staging_path:
            stream = await _request_body_stream(request)
            staged = await uploads.stage_stream(
                stream, staging_path, max_size=settings.telegram_max_file_size
            )

            _verify_staged(file, staged)

            if staged.size <= settings.telegram_bot_api_max_upload:
                # Small enough for the simple transport even though it came
                # through the backend — no reason to chunk it.
                message_id, tg_file_id, tg_unique_id = await uploads.upload_whole(
                    staged,
                    filename=file.name,
                    mime_type=file.mime_type,
                    credentials=credentials,
                )
                file.telegram_message_id = message_id
                file.telegram_file_id = tg_file_id
                file.telegram_file_unique_id = tg_unique_id
                file.size = staged.size
            else:
                await uploads.upload_chunked(session, file, staged, credentials)

            if file.sha256 is None:
                file.sha256 = staged.sha256

    await session.flush()
    await session.refresh(file, ["tags", "chunks"])

    await activity.record(
        session,
        action=ActivityAction.UPLOAD,
        user_id=user.id,
        file_id=file.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"size": file.size, "chunks": file.chunk_count, "path": "backend"},
    )
    return ok(FileDetailOut.from_model(file))


@router.get(
    "/{file_id}/ticket",
    response_model=Envelope[DownloadTicket],
    summary="How to fetch this file",
)
async def download_ticket(
    file_id: uuid.UUID, session: SessionDep, user: CurrentUser
) -> Envelope[DownloadTicket]:
    """Tell the client whether it can pull straight from Telegram.

    When it can, the bytes bypass this server entirely — the client combines the
    returned path with the bot token it already holds.
    """
    file = await file_service.get_file(session, user.id, file_id, include_deleted=False)
    proxy_url = f"{settings.api_prefix}/files/{file.id}/download"

    telegram_path: str | None = None
    if (
        not file.is_chunked
        and file.telegram_file_id
        and file.size <= settings.telegram_bot_api_max_upload
    ):
        credentials = await telegram_config.get_credentials(session, user.id)
        try:
            from app.providers.telegram import TelegramStorage

            meta = await TelegramStorage.call(
                credentials.bot_token, "getFile", data={"file_id": file.telegram_file_id}
            )
            telegram_path = meta.get("file_path")
        except TelegramError as exc:
            # Not fatal: the proxy path always works, so degrade rather than fail.
            log.info("ticket_getfile_failed", code=exc.code, file_id=str(file.id))

    return ok(
        DownloadTicket(
            mode="direct" if telegram_path else "proxy",
            proxy_url=proxy_url,
            telegram_file_path=telegram_path,
            size=file.size,
            mime_type=file.mime_type,
            name=file.name,
            is_encrypted=file.is_encrypted,
            is_chunked=file.is_chunked,
        )
    )


@router.get("/{file_id}/download", summary="Download a file")
async def download_file(
    file_id: uuid.UUID, request: Request, session: SessionDep, user: CurrentUser
) -> StreamingResponse:
    """Stream a file's bytes, reassembling chunks in order.

    Honours `Range`, so this endpoint also serves resumable downloads.
    """
    return await _stream_response(
        request, session, user.id, file_id, inline=False, honour_range=True
    )


@router.get("/{file_id}/stream", summary="Stream a file with Range support")
async def stream_file(
    file_id: uuid.UUID, request: Request, session: SessionDep, user: CurrentUser
) -> StreamingResponse:
    """Range-aware endpoint for media players.

    Returns `206 Partial Content` with a `Content-Range` header whenever the
    client asks for a window, which is what makes seeking work: the requested
    byte offset is mapped to the chunk holding it and an offset inside that chunk.
    """
    return await _stream_response(
        request, session, user.id, file_id, inline=True, honour_range=True
    )


# --- Helpers -----------------------------------------------------------


async def _stream_response(
    request: Request,
    session: SessionDep,
    user_id: uuid.UUID,
    file_id: uuid.UUID,
    *,
    inline: bool,
    honour_range: bool,
) -> StreamingResponse:
    file = await file_service.get_file(session, user_id, file_id, include_deleted=False)

    if file.telegram_channel_id is None or (
        file.telegram_message_id is None and not file.is_chunked
    ):
        raise BadRequestError(
            "This file has no stored bytes yet", code="FILE_NOT_UPLOADED"
        )

    credentials = await telegram_config.get_credentials(session, user_id)

    byte_range = downloads.parse_range(
        request.headers.get("range") if honour_range else None, file.size
    )
    # The plan is built now, while the session is alive: dependency teardown runs
    # before the streaming body is consumed.
    plan = downloads.build_plan(file, byte_range)

    headers = {
        "Content-Disposition": downloads.content_disposition(file.name, inline=inline),
        "Accept-Ranges": "bytes",
        "Content-Length": str(plan.length),
        # These bytes are user data behind an auth check — never let a shared
        # cache keep a copy.
        "Cache-Control": "private, no-store",
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


async def _request_body_stream(request: Request) -> AsyncIterator[bytes]:
    content_type = request.headers.get("content-type", "")

    if content_type.startswith("multipart/form-data"):
        form = await request.form()
        part = form.get("file")
        # Must be Starlette's UploadFile, not FastAPI's subclass: the multipart
        # parser constructs the base class, so checking the subclass here never
        # matches and every multipart upload would be rejected.
        if not isinstance(part, StarletteUploadFile):
            raise BadRequestError(
                "Expected a multipart field named 'file'", code="MISSING_FILE_PART"
            )
        return _iter_upload_file(part)

    return request.stream()


async def _iter_upload_file(upload: StarletteUploadFile) -> AsyncIterator[bytes]:
    try:
        while chunk := await upload.read(READ_CHUNK):
            yield chunk
    finally:
        await upload.close()


def _verify_staged(file: File, staged: uploads.StagedUpload) -> None:
    """The VERIFYING step of the upload state machine.

    A truncated or swapped body must not be recorded as a successful upload —
    the metadata would then describe bytes that do not exist.
    """
    if staged.size == 0:
        raise BadRequestError("The uploaded body was empty", code="EMPTY_UPLOAD")

    if file.size and staged.size != file.size:
        raise BadRequestError(
            "The uploaded byte count does not match the reserved size",
            code="SIZE_MISMATCH",
            details={"expected": file.size, "received": staged.size},
        )

    if file.sha256 and file.sha256 != staged.sha256:
        raise BadRequestError(
            "The uploaded bytes do not match the declared SHA-256",
            code="CHECKSUM_MISMATCH",
            details={"expected": file.sha256, "received": staged.sha256},
        )


async def _credentials_or_none(
    session: SessionDep, user_id: uuid.UUID
) -> StorageCredentials | None:
    """Credentials for remote deletion, or None if the channel is unbound.

    A user who unbound their channel must still be able to empty their trash;
    the metadata goes and the remote messages are simply left behind.
    """
    from app.core.errors import AppError

    try:
        return await telegram_config.get_credentials(session, user_id)
    except AppError:
        return None


async def _raw_json(request: Request) -> dict[str, object]:
    """Re-read the parsed body to distinguish 'null' from 'absent'."""
    try:
        body = await request.json()
    except Exception:
        return {}
    return body if isinstance(body, dict) else {}
