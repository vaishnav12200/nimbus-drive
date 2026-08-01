"""Folder tree operations.

The invariant this module exists to protect: ``folders.path`` always equals the
concatenation of the names from the root down to the node. Every write that can
break that — create, rename, move — repairs the whole subtree in the same
transaction.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import func, literal, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import rowcount
from app.core.errors import (
    BadRequestError,
    ConflictError,
    FolderNotEmptyError,
    FolderNotFoundError,
)
from app.core.logging import get_logger
from app.models import File, Folder

log = get_logger(__name__)

SEPARATOR = "/"
MAX_DEPTH = 32


def build_path(parent_path: str | None, name: str) -> str:
    return f"{parent_path or ''}{SEPARATOR}{name}"


async def get_folder(
    session: AsyncSession, user_id: uuid.UUID, folder_id: uuid.UUID
) -> Folder:
    """Fetch a folder, scoped to its owner.

    The `user_id` predicate is what makes a folder id in a URL insufficient
    authorisation — an id belonging to someone else reads as "not found", which
    also avoids confirming that it exists (cross-cutting rule 1).
    """
    result = await session.execute(
        select(Folder).where(Folder.id == folder_id, Folder.user_id == user_id)
    )
    folder = result.scalar_one_or_none()
    if folder is None:
        raise FolderNotFoundError(details={"folder_id": str(folder_id)})
    return folder


async def resolve_parent(
    session: AsyncSession, user_id: uuid.UUID, parent_id: uuid.UUID | None
) -> Folder | None:
    return None if parent_id is None else await get_folder(session, user_id, parent_id)


async def list_folders(
    session: AsyncSession, user_id: uuid.UUID, parent_id: uuid.UUID | None
) -> list[Folder]:
    condition = (
        Folder.parent_id.is_(None) if parent_id is None else Folder.parent_id == parent_id
    )
    result = await session.execute(
        select(Folder)
        .where(Folder.user_id == user_id, condition)
        .order_by(func.lower(Folder.name))
    )
    return list(result.scalars().all())


async def list_all_folders(session: AsyncSession, user_id: uuid.UUID) -> list[Folder]:
    """Every folder for one user, ordered by path — a whole tree in one query."""
    result = await session.execute(
        select(Folder).where(Folder.user_id == user_id).order_by(Folder.path)
    )
    return list(result.scalars().all())


async def create_folder(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    name: str,
    parent_id: uuid.UUID | None = None,
    color: str | None = None,
) -> Folder:
    parent = await resolve_parent(session, user_id, parent_id)

    if parent is not None and _depth(parent.path) >= MAX_DEPTH:
        raise BadRequestError(
            f"Folders cannot nest deeper than {MAX_DEPTH} levels",
            code="FOLDER_TOO_DEEP",
        )

    folder = Folder(
        user_id=user_id,
        parent_id=parent.id if parent else None,
        name=name,
        color=color,
        path=build_path(parent.path if parent else None, name),
    )
    session.add(folder)
    try:
        await session.flush()
    except IntegrityError as exc:
        await session.rollback()
        raise ConflictError(
            f"A folder named {name!r} already exists here",
            code="FOLDER_NAME_TAKEN",
            details={"name": name},
        ) from exc
    return folder


async def update_folder(
    session: AsyncSession,
    folder: Folder,
    *,
    name: str | None = None,
    color: str | None = None,
    parent_id: uuid.UUID | None = None,
    move: bool = False,
) -> Folder:
    """Rename, recolour and/or move a folder, repairing descendant paths.

    ``move`` distinguishes "``parent_id`` was not supplied" from "``parent_id``
    was explicitly set to null", which means *move to the root* — the two are
    indistinguishable from the value alone.
    """
    old_path = folder.path
    changed_path = False

    if move:
        new_parent = await resolve_parent(session, folder.user_id, parent_id)
        _assert_no_cycle(folder, new_parent)
        if new_parent is not None and _depth(new_parent.path) >= MAX_DEPTH:
            raise BadRequestError(
                f"Folders cannot nest deeper than {MAX_DEPTH} levels",
                code="FOLDER_TOO_DEEP",
            )
        folder.parent_id = new_parent.id if new_parent else None
        folder.path = build_path(new_parent.path if new_parent else None, folder.name)
        changed_path = True

    if name is not None and name != folder.name:
        folder.name = name
        parent_path = folder.path.rsplit(SEPARATOR, 1)[0]
        folder.path = build_path(parent_path or None, name)
        changed_path = True

    if color is not None:
        folder.color = color or None

    try:
        await session.flush()
    except IntegrityError as exc:
        await session.rollback()
        raise ConflictError(
            f"A folder named {folder.name!r} already exists in the destination",
            code="FOLDER_NAME_TAKEN",
        ) from exc

    if changed_path and folder.path != old_path:
        await _repath_descendants(session, folder.user_id, old_path, folder.path)

    return folder


def _assert_no_cycle(folder: Folder, new_parent: Folder | None) -> None:
    """Reject moves that would detach a subtree from the tree.

    Moving a folder into itself or into one of its own descendants creates a
    cycle: the subtree becomes unreachable from the root and the recursive path
    rewrite would never terminate.
    """
    if new_parent is None:
        return
    if new_parent.id == folder.id:
        raise BadRequestError("A folder cannot be moved into itself", code="FOLDER_CYCLE")
    if new_parent.path == folder.path or new_parent.path.startswith(
        folder.path + SEPARATOR
    ):
        raise BadRequestError(
            "A folder cannot be moved into one of its own subfolders",
            code="FOLDER_CYCLE",
        )


async def _repath_descendants(
    session: AsyncSession, user_id: uuid.UUID, old_path: str, new_path: str
) -> None:
    """Rewrite the path prefix of every descendant in a single statement.

    Doing this row-by-row in Python would be one round trip per descendant; a
    subtree of a few thousand folders makes that visibly slow.
    """
    prefix_length = len(old_path)
    result = await session.execute(
        update(Folder)
        .where(
            Folder.user_id == user_id,
            Folder.path.like(old_path + SEPARATOR + "%"),
        )
        .values(
            path=literal(new_path) + func.substr(Folder.path, prefix_length + 1),
            updated_at=datetime.now(UTC),
        )
    )
    changed = rowcount(result)
    if changed:
        log.info("folder_subtree_repathed", descendants=changed)


async def count_children(session: AsyncSession, folder: Folder) -> tuple[int, int]:
    """(subfolders, live files) directly inside this folder."""
    subfolders = await session.scalar(
        select(func.count())
        .select_from(Folder)
        .where(Folder.parent_id == folder.id, Folder.user_id == folder.user_id)
    )
    files = await session.scalar(
        select(func.count())
        .select_from(File)
        .where(
            File.folder_id == folder.id,
            File.user_id == folder.user_id,
            File.is_deleted.is_(False),
        )
    )
    return int(subfolders or 0), int(files or 0)


async def delete_folder(
    session: AsyncSession, folder: Folder, *, cascade: bool = False
) -> int:
    """Delete a folder. Returns the number of files moved to the trash.

    Default is **restrict**: a non-empty folder is a 409. The destructive
    interpretation of "delete this folder" is never the default.

    With ``cascade``, files in the subtree are *soft*-deleted (rule 4 — nothing is
    ever hard-deleted outside the 30-day purge) and their Telegram messages are
    left alone. Their ``folder_id`` becomes NULL when the folder rows go, so
    restoring one from the trash returns it to the root rather than to a folder
    that no longer exists.
    """
    subfolders, files = await count_children(session, folder)
    if not cascade and (subfolders or files):
        raise FolderNotEmptyError(
            details={"subfolder_count": subfolders, "file_count": files}
        )

    subtree_condition = (Folder.path == folder.path) | (
        Folder.path.like(folder.path + SEPARATOR + "%")
    )
    descendant_ids = list(
        (
            await session.execute(
                select(Folder.id).where(
                    Folder.user_id == folder.user_id, subtree_condition
                )
            )
        )
        .scalars()
        .all()
    )

    trashed = 0
    if cascade:
        result = await session.execute(
            update(File)
            .where(
                File.user_id == folder.user_id,
                File.folder_id.in_(descendant_ids),
                File.is_deleted.is_(False),
            )
            .values(is_deleted=True, deleted_at=datetime.now(UTC))
        )
        trashed = rowcount(result)

    # Folders are hard-deleted, so an offline client would otherwise never learn
    # they are gone — the row just stops appearing in deltas.
    from app.services import sync as sync_service

    await sync_service.record_deletions(
        session, folder.user_id, entity_type="folder", entity_ids=descendant_ids
    )

    await session.delete(folder)
    await session.flush()
    log.info("folder_deleted", cascade=cascade, files_trashed=trashed)
    return trashed


async def breadcrumbs(
    session: AsyncSession, folder: Folder
) -> list[tuple[uuid.UUID, str]]:
    """Ancestor chain, root first, excluding the folder itself.

    Derived from the materialized path: the ancestors of `/a/b/c` are exactly the
    folders whose path is a prefix of it, so this is one indexed query rather than
    a walk up `parent_id`.
    """
    segments = [s for s in folder.path.split(SEPARATOR) if s]
    ancestor_paths = [
        SEPARATOR + SEPARATOR.join(segments[: i + 1]) for i in range(len(segments) - 1)
    ]
    if not ancestor_paths:
        return []

    result = await session.execute(
        select(Folder.id, Folder.name, Folder.path).where(
            Folder.user_id == folder.user_id, Folder.path.in_(ancestor_paths)
        )
    )
    rows = {row.path: (row.id, row.name) for row in result}
    return [rows[p] for p in ancestor_paths if p in rows]


def _depth(path: str) -> int:
    return len([s for s in path.split(SEPARATOR) if s])
