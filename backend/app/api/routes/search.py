"""Search endpoint (spec §8.3)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Query
from pydantic import BaseModel

from app.api.deps import CurrentUser, PaginationDep, SessionDep
from app.core.envelope import Envelope, ok, page
from app.core.errors import BadRequestError
from app.models.enums import FileCategory, FileSort, SortOrder
from app.schemas.file import FileOut
from app.schemas.search import SearchFilters
from app.services import search as search_service

router = APIRouter(tags=["search"])


class TagCount(BaseModel):
    tag: str
    count: int


@router.get("/search", response_model=Envelope[list[FileOut]], summary="Search files")
async def search(
    session: SessionDep,
    user: CurrentUser,
    pagination: PaginationDep,
    q: Annotated[
        str | None, Query(description="Substring match on the file name")
    ] = None,
    filters: Annotated[
        str | None, Query(description="JSON filter object, per the spec")
    ] = None,
    type: Annotated[list[FileCategory] | None, Query()] = None,
    folder_id: Annotated[uuid.UUID | None, Query()] = None,
    date_from: Annotated[datetime | None, Query()] = None,
    date_to: Annotated[datetime | None, Query()] = None,
    size_min: Annotated[int | None, Query(ge=0)] = None,
    size_max: Annotated[int | None, Query(ge=0)] = None,
    tags: Annotated[
        str | None, Query(description="Comma-separated; a file must carry all of them")
    ] = None,
    is_favorite: Annotated[bool | None, Query()] = None,
    is_deleted: Annotated[bool, Query(description="Search the trash instead")] = False,
    sort: FileSort = FileSort.CREATED_AT,
    order: SortOrder = SortOrder.DESC,
) -> Envelope[list[FileOut]]:
    """Search metadata by name and filters.

    Filters can be passed either as the spec's `filters=<json>` blob or as the
    flat query parameters below; the flat form wins when both are supplied.
    """
    try:
        parsed = SearchFilters.parse_json(filters) or SearchFilters()
    except ValueError as exc:
        raise BadRequestError(str(exc), code="INVALID_FILTERS") from exc

    flat = SearchFilters(
        type=type,
        folder_id=folder_id,
        date_from=date_from,
        date_to=date_to,
        size_min=size_min,
        size_max=size_max,
        tags=tags,  # type: ignore[arg-type]  # validator splits the string
        is_favorite=is_favorite,
        is_deleted=is_deleted,
    )
    merged = parsed.model_copy(
        update={k: v for k, v in flat.model_dump().items() if v not in (None, False)}
    )
    merged.is_deleted = is_deleted or parsed.is_deleted

    if (
        merged.size_min is not None
        and merged.size_max is not None
        and merged.size_min > merged.size_max
    ):
        raise BadRequestError("size_min cannot exceed size_max", code="INVALID_FILTERS")

    rows, total = await search_service.search_files(
        session,
        user.id,
        query=q,
        filters=merged,
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


@router.get(
    "/search/tags", response_model=Envelope[list[TagCount]], summary="List used tags"
)
async def list_tags(session: SessionDep, user: CurrentUser) -> Envelope[list[TagCount]]:
    rows = await search_service.list_tags(session, user.id)
    return ok([TagCount(tag=tag, count=count) for tag, count in rows])
