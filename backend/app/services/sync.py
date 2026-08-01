"""Delta sync.

PostgreSQL is the source of truth; the client's SQLite is a cache. A client asks
"what changed since T?" and applies the answer in one transaction.

Two correctness problems the naive version gets wrong:

**The boundary.** A row committed while the sync query is running can carry an
``updated_at`` earlier than the timestamp we hand back, so the next delta —
filtering on ``updated_at > next_since`` — would never see it. The fix is to
return ``next_since = now() - OVERLAP_SECONDS``. A client re-fetches a few
seconds of already-applied changes, which is free because every delta is applied
as an upsert.

**Pagination.** Bulk operations stamp many rows with the *same* ``updated_at``
(one `UPDATE ... SET deleted_at = now()` covers a whole subtree). Paginating on
the timestamp alone would either skip rows or loop forever on a page boundary
inside such a group. Pagination is therefore keyset-based on the composite
``(updated_at, id)``, which is unique and totally ordered.
"""

from __future__ import annotations

import base64
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import Select, func, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.db import rowcount
from app.core.errors import BadRequestError
from app.core.logging import get_logger
from app.models import File, Folder, SyncTombstone
from app.models.sync import TOMBSTONE_RETENTION_DAYS

log = get_logger(__name__)

# Slack for in-flight transactions at the boundary. Well above any request this
# API serves, and cheap because re-applied deltas are idempotent.
OVERLAP_SECONDS = 5
MAX_PAGE = 500


@dataclass(frozen=True)
class Cursor:
    updated_at: datetime
    entity_id: uuid.UUID

    def encode(self) -> str:
        raw = f"{self.updated_at.isoformat()}|{self.entity_id}"
        return base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")

    @classmethod
    def decode(cls, value: str) -> Cursor:
        try:
            padded = value + "=" * (-len(value) % 4)
            raw = base64.urlsafe_b64decode(padded.encode()).decode()
            timestamp, _, entity_id = raw.rpartition("|")
            return cls(
                updated_at=datetime.fromisoformat(timestamp),
                entity_id=uuid.UUID(entity_id),
            )
        except Exception as exc:
            raise BadRequestError(
                "The sync cursor is malformed; restart the sync without it",
                code="INVALID_CURSOR",
            ) from exc


@dataclass
class SyncDelta:
    server_time: datetime
    next_since: datetime
    full_resync_required: bool = False
    has_more: bool = False
    next_cursor: str | None = None

    new_files: list[File] = field(default_factory=list)
    updated_files: list[File] = field(default_factory=list)
    deleted_files: list[uuid.UUID] = field(default_factory=list)

    new_folders: list[Folder] = field(default_factory=list)
    updated_folders: list[Folder] = field(default_factory=list)
    deleted_folders: list[uuid.UUID] = field(default_factory=list)


def _after_cursor(
    query: Select[Any], model: type[File] | type[Folder], cursor: Cursor | None
) -> Select[Any]:
    if cursor is None:
        return query
    return query.where(
        tuple_(model.updated_at, model.id) > (cursor.updated_at, cursor.entity_id)
    )


async def compute_delta(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    since: datetime | None,
    cursor: Cursor | None = None,
    limit: int = 200,
) -> SyncDelta:
    limit = min(max(limit, 1), MAX_PAGE)
    server_time = await session.scalar(select(func.now()))
    assert server_time is not None

    # A client that has been offline longer than tombstones are kept cannot be
    # brought up to date by a delta — it would silently keep folders that were
    # deleted while it was away.
    if since is not None:
        age = server_time - since
        if age > timedelta(days=TOMBSTONE_RETENTION_DAYS):
            return SyncDelta(
                server_time=server_time,
                next_since=server_time - timedelta(seconds=OVERLAP_SECONDS),
                full_resync_required=True,
            )

    delta = SyncDelta(
        server_time=server_time,
        next_since=server_time - timedelta(seconds=OVERLAP_SECONDS),
    )

    files = await _changed_files(session, user_id, since, cursor, limit + 1)
    folders = await _changed_folders(session, user_id, since, cursor, limit + 1)

    delta.has_more = len(files) > limit or len(folders) > limit
    files, folders = files[:limit], folders[:limit]

    if delta.has_more:
        # The cursor must sit at the furthest point *both* streams have reached,
        # or the next page would re-read one of them from too far back.
        positions: list[tuple[datetime, uuid.UUID]] = [
            (row.updated_at, row.id) for row in files
        ]
        positions += [(row.updated_at, row.id) for row in folders]
        tail = max(positions, default=None)
        if tail is not None:
            delta.next_cursor = Cursor(updated_at=tail[0], entity_id=tail[1]).encode()

    for file in files:
        if file.is_deleted:
            delta.deleted_files.append(file.id)
        elif (since is not None and file.created_at > since) or since is None:
            delta.new_files.append(file)
        else:
            delta.updated_files.append(file)

    for folder in folders:
        if since is None or folder.created_at > since:
            delta.new_folders.append(folder)
        else:
            delta.updated_folders.append(folder)

    if since is not None:
        purged_files, deleted_folders = await _tombstones(session, user_id, since)
        delta.deleted_files.extend(purged_files)
        delta.deleted_folders.extend(deleted_folders)

    return delta


async def _changed_files(
    session: AsyncSession,
    user_id: uuid.UUID,
    since: datetime | None,
    cursor: Cursor | None,
    limit: int,
) -> list[File]:
    query = (
        select(File)
        .options(selectinload(File.tags), selectinload(File.chunks))
        .where(File.user_id == user_id)
    )
    if since is not None:
        query = query.where(File.updated_at > since)
    query = _after_cursor(query, File, cursor)
    query = query.order_by(File.updated_at.asc(), File.id.asc()).limit(limit)
    return list((await session.execute(query)).scalars().all())


async def _changed_folders(
    session: AsyncSession,
    user_id: uuid.UUID,
    since: datetime | None,
    cursor: Cursor | None,
    limit: int,
) -> list[Folder]:
    query = select(Folder).where(Folder.user_id == user_id)
    if since is not None:
        query = query.where(Folder.updated_at > since)
    query = _after_cursor(query, Folder, cursor)
    query = query.order_by(Folder.updated_at.asc(), Folder.id.asc()).limit(limit)
    return list((await session.execute(query)).scalars().all())


async def _tombstones(
    session: AsyncSession, user_id: uuid.UUID, since: datetime
) -> tuple[list[uuid.UUID], list[uuid.UUID]]:
    result = await session.execute(
        select(SyncTombstone.entity_type, SyncTombstone.entity_id).where(
            SyncTombstone.user_id == user_id, SyncTombstone.deleted_at > since
        )
    )
    files: list[uuid.UUID] = []
    folders: list[uuid.UUID] = []
    for entity_type, entity_id in result:
        (files if entity_type == "file" else folders).append(entity_id)
    return files, folders


async def record_deletion(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    entity_type: str,
    entity_id: uuid.UUID,
) -> None:
    """Leave a tombstone so offline clients learn about a hard delete."""
    session.add(
        SyncTombstone(user_id=user_id, entity_type=entity_type, entity_id=entity_id)
    )
    await session.flush()


async def record_deletions(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    entity_type: str,
    entity_ids: list[uuid.UUID],
) -> None:
    for entity_id in entity_ids:
        session.add(
            SyncTombstone(user_id=user_id, entity_type=entity_type, entity_id=entity_id)
        )
    if entity_ids:
        await session.flush()


async def purge_tombstones(session: AsyncSession) -> int:
    from sqlalchemy import delete

    cutoff = datetime.now(UTC) - timedelta(days=TOMBSTONE_RETENTION_DAYS)
    result = await session.execute(
        delete(SyncTombstone).where(SyncTombstone.deleted_at < cutoff)
    )
    return rowcount(result)


async def snapshot_counts(session: AsyncSession, user_id: uuid.UUID) -> tuple[int, int]:
    """(live files, folders) — lets a client sanity-check a completed resync."""
    files = await session.scalar(
        select(func.count())
        .select_from(File)
        .where(File.user_id == user_id, File.is_deleted.is_(False))
    )
    folders = await session.scalar(
        select(func.count()).select_from(Folder).where(Folder.user_id == user_id)
    )
    return int(files or 0), int(folders or 0)


def parse_since(raw: str | None) -> datetime | None:
    """Accept an ISO 8601 string or a Unix timestamp; always return UTC-aware."""
    if not raw:
        return None
    try:
        value = (
            datetime.fromtimestamp(float(raw), tz=UTC)
            if raw.replace(".", "", 1).isdigit()
            else datetime.fromisoformat(raw.replace("Z", "+00:00"))
        )
    except ValueError as exc:
        raise BadRequestError(
            "`since` must be an ISO 8601 timestamp or a Unix epoch value",
            code="INVALID_SINCE",
        ) from exc

    # A naive timestamp is ambiguous; the API is UTC-only (rule 6).
    return value if value.tzinfo else value.replace(tzinfo=UTC)
