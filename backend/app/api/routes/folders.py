"""Folder endpoints."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Query, Request, status

from app.api.deps import ContextDep, CurrentUser, SessionDep
from app.core.envelope import Ack, Envelope, ok
from app.models import ActivityAction
from app.schemas.folder import (
    FolderBreadcrumb,
    FolderCreate,
    FolderDetailOut,
    FolderOut,
    FolderUpdate,
)
from app.services import activity
from app.services import folders as folder_service

router = APIRouter(prefix="/folders", tags=["folders"])


@router.get("", response_model=Envelope[list[FolderOut]], summary="List folders")
async def list_folders(
    session: SessionDep,
    user: CurrentUser,
    parent_id: Annotated[uuid.UUID | None, Query()] = None,
    tree: Annotated[
        bool, Query(description="Return every folder instead of one level")
    ] = False,
) -> Envelope[list[FolderOut]]:
    """One level by default; `tree=true` returns the whole hierarchy.

    The tree form exists so the mobile client can build its folder picker in a
    single request rather than one per expanded node.
    """
    rows = (
        await folder_service.list_all_folders(session, user.id)
        if tree
        else await folder_service.list_folders(session, user.id, parent_id)
    )
    return ok([FolderOut.model_validate(row) for row in rows])


@router.post(
    "",
    response_model=Envelope[FolderOut],
    status_code=status.HTTP_201_CREATED,
    summary="Create a folder",
)
async def create_folder(
    payload: FolderCreate, session: SessionDep, user: CurrentUser, ctx: ContextDep
) -> Envelope[FolderOut]:
    folder = await folder_service.create_folder(
        session,
        user.id,
        name=payload.name,
        parent_id=payload.parent_id,
        color=payload.color,
    )
    await activity.record(
        session,
        action=ActivityAction.FOLDER_CREATE,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"folder_id": str(folder.id), "path": folder.path},
    )
    return ok(FolderOut.model_validate(folder))


@router.get(
    "/{folder_id}", response_model=Envelope[FolderDetailOut], summary="Get a folder"
)
async def get_folder(
    folder_id: uuid.UUID, session: SessionDep, user: CurrentUser
) -> Envelope[FolderDetailOut]:
    """A folder with its breadcrumb trail and direct child counts."""
    folder = await folder_service.get_folder(session, user.id, folder_id)
    trail = await folder_service.breadcrumbs(session, folder)
    subfolders, files = await folder_service.count_children(session, folder)

    detail = FolderDetailOut.model_validate(folder)
    detail.breadcrumbs = [FolderBreadcrumb(id=fid, name=name) for fid, name in trail]
    detail.subfolder_count = subfolders
    detail.file_count = files
    return ok(detail)


@router.patch(
    "/{folder_id}", response_model=Envelope[FolderOut], summary="Rename, recolour or move"
)
async def update_folder(
    folder_id: uuid.UUID,
    payload: FolderUpdate,
    request: Request,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
) -> Envelope[FolderOut]:
    """Update a folder, rewriting every descendant's materialized path.

    `parent_id: null` moves the folder to the root; omitting `parent_id` leaves
    it where it is. Moving a folder into its own subtree is rejected.
    """
    folder = await folder_service.get_folder(session, user.id, folder_id)

    try:
        body = await request.json()
    except Exception:
        body = {}
    move = isinstance(body, dict) and "parent_id" in body

    folder = await folder_service.update_folder(
        session,
        folder,
        name=payload.name,
        color=payload.color,
        parent_id=payload.parent_id,
        move=move,
    )
    await activity.record(
        session,
        action=ActivityAction.FOLDER_MOVE if move else ActivityAction.FOLDER_RENAME,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"folder_id": str(folder.id), "path": folder.path},
    )
    return ok(FolderOut.model_validate(folder))


@router.delete("/{folder_id}", response_model=Envelope[Ack], summary="Delete a folder")
async def delete_folder(
    folder_id: uuid.UUID,
    session: SessionDep,
    user: CurrentUser,
    ctx: ContextDep,
    cascade: Annotated[
        bool,
        Query(description="Also delete subfolders and move their files to the trash"),
    ] = False,
) -> Envelope[Ack]:
    """Restrict by default: a non-empty folder returns `FOLDER_NOT_EMPTY`.

    With `cascade=true` the subtree goes and its files are moved to the trash —
    soft-deleted, never destroyed, so nothing is unrecoverable by accident.
    Restoring one afterwards places it at the root.
    """
    folder = await folder_service.get_folder(session, user.id, folder_id)
    path = folder.path
    trashed = await folder_service.delete_folder(session, folder, cascade=cascade)
    await activity.record(
        session,
        action=ActivityAction.FOLDER_DELETE,
        user_id=user.id,
        ip_address=ctx.ip_address,
        user_agent=ctx.user_agent,
        details={"path": path, "cascade": cascade, "files_trashed": trashed},
    )
    return ok(Ack())
