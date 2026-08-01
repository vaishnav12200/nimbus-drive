"""The uniform success envelope shared by every endpoint.

    {"success": true, "data": {...}, "meta": {"page": 1, "limit": 50, "total": 247}}

`Envelope[T]` is a real generic model so the OpenAPI schema stays accurate instead of
degrading to a bare object.
"""

from __future__ import annotations

import math
from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

T = TypeVar("T")


class PageMeta(BaseModel):
    page: int = Field(..., ge=1, description="1-indexed page number")
    limit: int = Field(..., ge=1, description="Page size that was applied")
    total: int = Field(..., ge=0, description="Total rows matching the query")
    pages: int = Field(..., ge=0, description="Total number of pages")

    @classmethod
    def build(cls, *, total: int, limit: int, offset: int) -> PageMeta:
        limit = max(limit, 1)
        return cls(
            page=(offset // limit) + 1,
            limit=limit,
            total=total,
            pages=math.ceil(total / limit) if total else 0,
        )


class Envelope(BaseModel, Generic[T]):
    model_config = ConfigDict(from_attributes=True)

    success: bool = True
    data: T
    meta: PageMeta | None = None


class ErrorDetail(BaseModel):
    code: str
    message: str
    details: dict[str, object] | None = None


class ErrorEnvelope(BaseModel):
    """Documents the failure shape for OpenAPI; produced by the exception handlers."""

    success: bool = False
    error: ErrorDetail


class Ack(BaseModel):
    """Payload for endpoints whose only meaningful result is 'it worked'."""

    ok: bool = True


def ok(data: T, meta: PageMeta | None = None) -> Envelope[T]:
    return Envelope[T](success=True, data=data, meta=meta)


def page(items: T, *, total: int, limit: int, offset: int) -> Envelope[T]:
    return Envelope[T](
        success=True,
        data=items,
        meta=PageMeta.build(total=total, limit=limit, offset=offset),
    )
