"""Delta sync endpoint (spec §7)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field

from app.api.deps import CurrentUser, SessionDep
from app.core.envelope import Envelope, ok
from app.schemas.file import FileOut
from app.schemas.folder import FolderOut
from app.services import sync as sync_service

router = APIRouter(tags=["sync"])


class SyncOut(BaseModel):
    """One delta batch.

    `next_since` is the value to send on the following sync — it is deliberately
    a few seconds behind `server_time` so a row committed during this request
    cannot fall through the boundary. Apply every list as an **upsert**: the
    overlap means a client will occasionally see a change it already has.
    """

    server_time: datetime
    next_since: datetime
    full_resync_required: bool = Field(
        default=False,
        description="The client has been away longer than deletions are tracked; "
        "discard the local cache and resync from scratch",
    )
    has_more: bool = False
    next_cursor: str | None = None

    new_files: list[FileOut] = Field(default_factory=list)
    updated_files: list[FileOut] = Field(default_factory=list)
    deleted_files: list[uuid.UUID] = Field(default_factory=list)

    new_folders: list[FolderOut] = Field(default_factory=list)
    updated_folders: list[FolderOut] = Field(default_factory=list)
    deleted_folders: list[uuid.UUID] = Field(default_factory=list)


class SnapshotOut(BaseModel):
    file_count: int
    folder_count: int
    server_time: datetime


@router.get("/sync", response_model=Envelope[SyncOut], summary="Fetch changes")
async def sync(
    session: SessionDep,
    user: CurrentUser,
    since: Annotated[
        str | None,
        Query(description="ISO 8601 timestamp or Unix epoch; omit for a full sync"),
    ] = None,
    cursor: Annotated[
        str | None, Query(description="Continuation token from a previous `has_more`")
    ] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 200,
) -> Envelope[SyncOut]:
    """Return everything that changed since `since`.

    Omitting `since` returns the full state as `new_*`. Soft-deleted files appear
    in `deleted_files`, and folders — which are hard-deleted — are reported from
    tombstones, so an offline client converges either way.

    When `has_more` is set, call again with the returned `cursor` *and the same
    `since`* until it clears, then store `next_since`.
    """
    parsed_since = sync_service.parse_since(since)
    parsed_cursor = sync_service.Cursor.decode(cursor) if cursor else None

    delta = await sync_service.compute_delta(
        session, user.id, since=parsed_since, cursor=parsed_cursor, limit=limit
    )

    return ok(
        SyncOut(
            server_time=delta.server_time,
            next_since=delta.next_since,
            full_resync_required=delta.full_resync_required,
            has_more=delta.has_more,
            next_cursor=delta.next_cursor,
            new_files=[FileOut.from_model(f) for f in delta.new_files],
            updated_files=[FileOut.from_model(f) for f in delta.updated_files],
            deleted_files=delta.deleted_files,
            new_folders=[FolderOut.model_validate(f) for f in delta.new_folders],
            updated_folders=[FolderOut.model_validate(f) for f in delta.updated_folders],
            deleted_folders=delta.deleted_folders,
        )
    )


@router.get(
    "/sync/snapshot",
    response_model=Envelope[SnapshotOut],
    summary="Row counts for verifying a resync",
)
async def snapshot(session: SessionDep, user: CurrentUser) -> Envelope[SnapshotOut]:
    """Server-side counts a client can compare against after a full resync."""
    from datetime import UTC

    files, folders = await sync_service.snapshot_counts(session, user.id)
    return ok(
        SnapshotOut(
            file_count=files,
            folder_count=folders,
            server_time=datetime.now(UTC),
        )
    )
