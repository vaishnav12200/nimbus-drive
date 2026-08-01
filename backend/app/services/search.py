"""Metadata search.

Everything is answered from PostgreSQL. Telegram's own message search is never
used: it cannot see folders, tags or the trash, and it would leak the query to a
third party.
"""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.errors import BadRequestError
from app.models import File, FileTag
from app.models.enums import FileCategory, FileSort, SortOrder
from app.schemas.search import (
    CATEGORY_EXACT,
    CATEGORY_PREFIXES,
    DOCUMENT_TEXT_PREFIX,
    SearchFilters,
)

MIN_QUERY_LENGTH = 1


def _category_condition(categories: list[FileCategory]) -> Any:
    clauses: list[Any] = []
    known_prefixes = [p for prefixes in CATEGORY_PREFIXES.values() for p in prefixes]
    known_exact = [m for values in CATEGORY_EXACT.values() for m in values]

    for category in categories:
        for prefix in CATEGORY_PREFIXES.get(category, ()):
            clauses.append(File.mime_type.startswith(prefix))
        exact = CATEGORY_EXACT.get(category, ())
        if exact:
            clauses.append(File.mime_type.in_(exact))
        if category is FileCategory.DOCUMENT:
            clauses.append(File.mime_type.startswith(DOCUMENT_TEXT_PREFIX))
        if category is FileCategory.OTHER:
            # "Other" is the complement of every named bucket, so it has to be
            # expressed as a negation rather than a list.
            clauses.append(
                and_(
                    *[~File.mime_type.startswith(p) for p in known_prefixes],
                    ~File.mime_type.startswith(DOCUMENT_TEXT_PREFIX),
                    File.mime_type.notin_(known_exact),
                )
            )
    return or_(*clauses) if clauses else None


def build_conditions(
    user_id: uuid.UUID, query: str | None, filters: SearchFilters
) -> list[Any]:
    conditions: list[Any] = [
        File.user_id == user_id,
        File.is_deleted.is_(filters.is_deleted),
    ]

    if query:
        # ILIKE '%q%' is what the pg_trgm GIN index on `name` accelerates; a
        # to_tsvector match would need whole words and would miss "report2026".
        pattern = f"%{_escape_like(query)}%"
        conditions.append(File.name.ilike(pattern, escape="\\"))

    if filters.folder_id is not None:
        conditions.append(File.folder_id == filters.folder_id)
    if filters.type:
        condition = _category_condition(filters.type)
        if condition is not None:
            conditions.append(condition)
    if filters.date_from is not None:
        conditions.append(File.created_at >= filters.date_from)
    if filters.date_to is not None:
        conditions.append(File.created_at <= filters.date_to)
    if filters.size_min is not None:
        conditions.append(File.size >= filters.size_min)
    if filters.size_max is not None:
        conditions.append(File.size <= filters.size_max)
    if filters.is_favorite is not None:
        conditions.append(File.is_favorite.is_(filters.is_favorite))

    if filters.tags:
        # Every requested tag must be present, so this is an AND over EXISTS
        # rather than one IN — `tags=invoice,2026` means both, not either.
        for tag in filters.tags:
            conditions.append(
                select(FileTag.file_id)
                .where(FileTag.file_id == File.id, FileTag.tag == tag)
                .exists()
            )

    return conditions


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


async def search_files(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    query: str | None = None,
    filters: SearchFilters | None = None,
    sort: FileSort = FileSort.CREATED_AT,
    order: SortOrder = SortOrder.DESC,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[File], int]:
    filters = filters or SearchFilters()

    if query is not None:
        query = query.strip()
        if len(query) < MIN_QUERY_LENGTH:
            raise BadRequestError("The search query is empty", code="EMPTY_SEARCH_QUERY")

    conditions = build_conditions(user_id, query, filters)

    total = await session.scalar(
        select(func.count()).select_from(File).where(and_(*conditions))
    )

    column = {
        FileSort.NAME: func.lower(File.name),
        FileSort.SIZE: File.size,
        FileSort.CREATED_AT: File.created_at,
        FileSort.UPDATED_AT: File.updated_at,
    }[sort]
    direction = column.desc() if order is SortOrder.DESC else column.asc()

    rows = await session.execute(
        select(File)
        .options(selectinload(File.tags), selectinload(File.chunks))
        .where(and_(*conditions))
        .order_by(direction, File.id.asc())
        .limit(limit)
        .offset(offset)
    )
    return list(rows.scalars().all()), int(total or 0)


async def list_tags(session: AsyncSession, user_id: uuid.UUID) -> list[tuple[str, int]]:
    """Every tag this user has used, with counts — for a filter chip row."""
    result = await session.execute(
        select(FileTag.tag, func.count())
        .join(File, File.id == FileTag.file_id)
        .where(File.user_id == user_id, File.is_deleted.is_(False))
        .group_by(FileTag.tag)
        .order_by(func.count().desc(), FileTag.tag)
    )
    return [(row[0], int(row[1])) for row in result]
