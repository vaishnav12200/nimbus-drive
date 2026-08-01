"""File metadata operations.

**Copy semantics.** ``POST /api/files/{id}/copy`` creates a second metadata row
pointing at the *same* Telegram message — copying 500 MB of bytes to make a
second name for them would be absurd. The consequence is that remote bytes may
be referenced by more than one row, so nothing here ever deletes a Telegram
message. Only :func:`purge_file` does, and only after confirming no surviving row
still references that ``(channel_id, message_id)``. This resolves the "refcount
vs copy-on-write" question in the build plan in favour of refcounting.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import Select, and_, delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import settings
from app.core.errors import BadRequestError, FileMissingError
from app.core.logging import get_logger
from app.models import File, FileChunk, FileTag, Folder, StorageProvider
from app.models.enums import FileSort, SortOrder
from app.providers import get_provider
from app.providers.base import StorageCredentials, StorageRef
from app.services import folders as folder_service

log = get_logger(__name__)

COPY_SUFFIX = " (copy)"


def _base_query() -> Select[tuple[File]]:
    return select(File).options(selectinload(File.tags), selectinload(File.chunks))


async def get_file(
    session: AsyncSession,
    user_id: uuid.UUID,
    file_id: uuid.UUID,
    *,
    include_deleted: bool = True,
) -> File:
    """Fetch one file, scoped to its owner (cross-cutting rule 1)."""
    query = _base_query().where(File.id == file_id, File.user_id == user_id)
    if not include_deleted:
        query = query.where(File.is_deleted.is_(False))

    file = (await session.execute(query)).scalar_one_or_none()
    if file is None:
        raise FileMissingError(details={"file_id": str(file_id)})
    return file


async def list_files(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    folder_id: uuid.UUID | None = None,
    root_only: bool = False,
    is_deleted: bool = False,
    is_favorite: bool | None = None,
    sort: FileSort = FileSort.CREATED_AT,
    order: SortOrder = SortOrder.DESC,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[File], int]:
    """List files with a total count. Returns ``(rows, total)``."""
    conditions = [File.user_id == user_id, File.is_deleted.is_(is_deleted)]

    if root_only:
        conditions.append(File.folder_id.is_(None))
    elif folder_id is not None:
        conditions.append(File.folder_id == folder_id)

    if is_favorite is not None:
        conditions.append(File.is_favorite.is_(is_favorite))

    total = await session.scalar(
        select(func.count()).select_from(File).where(and_(*conditions))
    )

    query = (
        _base_query()
        .where(and_(*conditions))
        .order_by(*_order_by(sort, order))
        .limit(limit)
        .offset(offset)
    )
    rows = list((await session.execute(query)).scalars().all())
    return rows, int(total or 0)


def _order_by(sort: FileSort, order: SortOrder) -> tuple[Any, ...]:
    column = {
        FileSort.NAME: func.lower(File.name),
        FileSort.SIZE: File.size,
        FileSort.CREATED_AT: File.created_at,
        FileSort.UPDATED_AT: File.updated_at,
    }[sort]
    direction = column.desc() if order is SortOrder.DESC else column.asc()
    # `id` breaks ties so pagination cannot show or skip a row when several
    # share a sort value — without it, page 2 can repeat a row from page 1.
    return (direction, File.id.asc())


# --- Creation ----------------------------------------------------------


async def create_file(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    name: str,
    original_name: str,
    size: int,
    mime_type: str,
    channel_id: int,
    telegram_message_id: int | None = None,
    telegram_file_id: str | None = None,
    telegram_file_unique_id: str | None = None,
    sha256: str | None = None,
    folder_id: uuid.UUID | None = None,
    is_encrypted: bool = False,
    tags: list[str] | None = None,
    storage_provider: StorageProvider = StorageProvider.TELEGRAM,
) -> File:
    if folder_id is not None:
        # Validates ownership as a side effect: a folder belonging to someone
        # else raises FOLDER_NOT_FOUND rather than silently filing the row there.
        await folder_service.get_folder(session, user_id, folder_id)

    file = File(
        user_id=user_id,
        folder_id=folder_id,
        name=name,
        original_name=original_name,
        size=size,
        mime_type=mime_type,
        sha256=sha256,
        storage_provider=storage_provider,
        telegram_message_id=telegram_message_id,
        telegram_file_id=telegram_file_id,
        telegram_file_unique_id=telegram_file_unique_id,
        telegram_channel_id=channel_id,
        is_encrypted=is_encrypted,
    )
    session.add(file)
    await session.flush()

    if tags:
        await set_tags(session, file, tags)

    await session.refresh(file, ["tags", "chunks"])
    return file


async def find_duplicate(
    session: AsyncSession, user_id: uuid.UUID, sha256: str
) -> File | None:
    """Server-side dedup: has this user already stored these exact bytes?

    The digest is over the *plaintext*, so an encrypted upload still matches its
    unencrypted twin (cross-cutting rule 5).
    """
    result = await session.execute(
        _base_query()
        .where(
            File.user_id == user_id,
            File.sha256 == sha256,
            File.is_deleted.is_(False),
        )
        .order_by(File.created_at.asc())
        .limit(1)
    )
    return result.scalar_one_or_none()


# --- Mutation ----------------------------------------------------------


async def set_tags(session: AsyncSession, file: File, tags: list[str]) -> None:
    """Replace a file's tag set."""
    await session.execute(delete(FileTag).where(FileTag.file_id == file.id))
    for tag in {t.strip().lower() for t in tags if t and t.strip()}:
        session.add(FileTag(file_id=file.id, tag=tag))
    await session.flush()
    await session.refresh(file, ["tags"])


async def update_file(
    session: AsyncSession,
    file: File,
    *,
    name: str | None = None,
    folder_id: uuid.UUID | None = None,
    move: bool = False,
    is_favorite: bool | None = None,
    tags: list[str] | None = None,
) -> File:
    if name is not None:
        file.name = name
    if move:
        if folder_id is not None:
            await folder_service.get_folder(session, file.user_id, folder_id)
        file.folder_id = folder_id
    if is_favorite is not None:
        file.is_favorite = is_favorite
    if tags is not None:
        await set_tags(session, file, tags)

    # Touch `updated_at` even for a tags-only change so delta sync notices it.
    file.updated_at = datetime.now(UTC)
    await session.flush()
    return file


async def soft_delete(session: AsyncSession, file: File) -> File:
    """Move a file to the trash. The Telegram message is left untouched."""
    if not file.is_deleted:
        file.is_deleted = True
        file.deleted_at = datetime.now(UTC)
        await session.flush()
    return file


async def restore(session: AsyncSession, file: File) -> File:
    """Bring a file back from the trash.

    If its folder was deleted meanwhile, `folder_id` is already NULL and the file
    reappears at the root — the alternative would be resurrecting a folder tree
    the user deliberately removed.
    """
    if file.is_deleted:
        file.is_deleted = False
        file.deleted_at = None
        await session.flush()
    return file


async def move_file(
    session: AsyncSession, file: File, target_folder_id: uuid.UUID | None
) -> File:
    return await update_file(session, file, folder_id=target_folder_id, move=True)


async def copy_file(
    session: AsyncSession,
    file: File,
    *,
    target_folder_id: uuid.UUID | None = None,
    name: str | None = None,
) -> File:
    """Duplicate the metadata row; the Telegram bytes are shared, not re-uploaded."""
    if target_folder_id is not None:
        await folder_service.get_folder(session, file.user_id, target_folder_id)

    copy = File(
        user_id=file.user_id,
        folder_id=target_folder_id,
        name=name or _copy_name(file.name),
        original_name=file.original_name,
        size=file.size,
        mime_type=file.mime_type,
        sha256=file.sha256,
        storage_provider=file.storage_provider,
        telegram_message_id=file.telegram_message_id,
        telegram_file_id=file.telegram_file_id,
        telegram_file_unique_id=file.telegram_file_unique_id,
        telegram_channel_id=file.telegram_channel_id,
        is_chunked=file.is_chunked,
        chunk_count=file.chunk_count,
        is_encrypted=file.is_encrypted,
    )
    session.add(copy)
    await session.flush()

    # Chunk rows are per-file, but they point at the same Telegram messages.
    for chunk in file.chunks:
        session.add(
            FileChunk(
                file_id=copy.id,
                chunk_index=chunk.chunk_index,
                size=chunk.size,
                offset=chunk.offset,
                telegram_message_id=chunk.telegram_message_id,
                telegram_file_id=chunk.telegram_file_id,
                telegram_file_unique_id=chunk.telegram_file_unique_id,
            )
        )
    if file.tags:
        for tag in file.tag_names:
            session.add(FileTag(file_id=copy.id, tag=tag))

    await session.flush()
    await session.refresh(copy, ["tags", "chunks"])
    return copy


def _copy_name(name: str) -> str:
    stem, dot, extension = name.rpartition(".")
    if dot and stem:
        return f"{stem}{COPY_SUFFIX}.{extension}"
    return f"{name}{COPY_SUFFIX}"


# --- Purge -------------------------------------------------------------


async def is_last_reference(session: AsyncSession, file: File) -> bool:
    """True when no other live row points at this file's Telegram message.

    Copies share their bytes, so deleting the remote message while a sibling row
    still references it would silently break that sibling.
    """
    if file.telegram_message_id is None or file.telegram_channel_id is None:
        return False

    others = await session.scalar(
        select(func.count())
        .select_from(File)
        .where(
            File.id != file.id,
            File.telegram_channel_id == file.telegram_channel_id,
            File.telegram_message_id == file.telegram_message_id,
        )
    )
    return not others


async def _chunk_message_is_shared(
    session: AsyncSession, file: File, chunk: FileChunk
) -> bool:
    others = await session.scalar(
        select(func.count())
        .select_from(FileChunk)
        .join(File, File.id == FileChunk.file_id)
        .where(
            FileChunk.file_id != file.id,
            FileChunk.telegram_message_id == chunk.telegram_message_id,
            File.telegram_channel_id == file.telegram_channel_id,
        )
    )
    return bool(others)


async def purge_file(
    session: AsyncSession,
    file: File,
    credentials: StorageCredentials | None,
    *,
    delete_remote: bool = True,
) -> None:
    """Hard-delete a file and, when safe, its bytes in Telegram.

    Remote deletion is best-effort: if Telegram refuses, the metadata row still
    goes. Leaving a dangling row because a message was already removed by hand in
    the channel would make the trash impossible to empty.
    """
    if delete_remote and credentials is not None:
        provider = get_provider(file.storage_provider)
        channel_id = file.telegram_channel_id or credentials.channel_id

        targets: list[StorageRef] = []
        if file.telegram_message_id is not None and await is_last_reference(
            session, file
        ):
            targets.append(
                StorageRef(
                    channel_id=channel_id,
                    message_id=file.telegram_message_id,
                    file_id=file.telegram_file_id,
                )
            )
        for chunk in file.chunks:
            if not await _chunk_message_is_shared(session, file, chunk):
                targets.append(
                    StorageRef(
                        channel_id=channel_id, message_id=chunk.telegram_message_id
                    )
                )

        for ref in targets:
            try:
                await provider.delete(ref, credentials)
            except Exception as exc:
                log.warning(
                    "remote_delete_failed",
                    message_id=ref.message_id,
                    error=type(exc).__name__,
                    exc_info=exc,
                )

    # Once the row is gone it cannot appear in a delta, so leave a tombstone for
    # clients that were offline when it was purged.
    from app.services import sync as sync_service

    await sync_service.record_deletion(
        session, file.user_id, entity_type="file", entity_id=file.id
    )

    await session.delete(file)
    await session.flush()


async def list_purgeable(
    session: AsyncSession, *, older_than_days: int | None = None, limit: int = 500
) -> list[File]:
    """Trashed files past the retention window, oldest first."""
    days = settings.trash_retention_days if older_than_days is None else older_than_days
    cutoff = datetime.now(UTC) - timedelta(days=days)
    result = await session.execute(
        _base_query()
        .where(
            File.is_deleted.is_(True),
            File.deleted_at.is_not(None),
            File.deleted_at < cutoff,
        )
        .order_by(File.deleted_at.asc())
        .limit(limit)
    )
    return list(result.scalars().all())


async def empty_trash(session: AsyncSession, user_id: uuid.UUID) -> list[File]:
    result = await session.execute(
        _base_query().where(File.user_id == user_id, File.is_deleted.is_(True))
    )
    return list(result.scalars().all())


# --- Storage helpers ---------------------------------------------------


def storage_ref(file: File) -> StorageRef:
    if file.telegram_channel_id is None or file.telegram_message_id is None:
        raise BadRequestError(
            "This file has no stored bytes yet",
            code="FILE_NOT_UPLOADED",
            details={"file_id": str(file.id)},
        )
    return StorageRef(
        channel_id=file.telegram_channel_id,
        message_id=file.telegram_message_id,
        file_id=file.telegram_file_id,
        file_unique_id=file.telegram_file_unique_id,
    )


async def total_usage(session: AsyncSession, user_id: uuid.UUID) -> tuple[int, int]:
    """(file count, total bytes) for live files, for a storage-usage display."""
    row = (
        await session.execute(
            select(func.count(), func.coalesce(func.sum(File.size), 0)).where(
                File.user_id == user_id, File.is_deleted.is_(False)
            )
        )
    ).one()
    return int(row[0]), int(row[1])


async def folder_ids_in_subtree(
    session: AsyncSession, user_id: uuid.UUID, folder: Folder
) -> list[uuid.UUID]:
    result = await session.execute(
        select(Folder.id).where(
            Folder.user_id == user_id,
            or_(
                Folder.path == folder.path,
                Folder.path.like(folder.path + folder_service.SEPARATOR + "%"),
            ),
        )
    )
    return list(result.scalars().all())
