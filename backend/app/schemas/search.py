"""Search filter schema."""

from __future__ import annotations

import json
import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator

from app.models.enums import FileCategory


class SearchFilters(BaseModel):
    """The spec's `filters` object (§8.3).

    Accepted either as a JSON blob in `?filters=` or as flat query parameters —
    the flat form is far easier to construct by hand and to read in a log.
    """

    type: list[FileCategory] | None = None
    folder_id: uuid.UUID | None = None
    date_from: datetime | None = None
    date_to: datetime | None = None
    size_min: int | None = Field(default=None, ge=0)
    size_max: int | None = Field(default=None, ge=0)
    tags: list[str] | None = None
    is_favorite: bool | None = None
    is_deleted: bool = False

    @field_validator("type", mode="before")
    @classmethod
    def _coerce_type(cls, v: object) -> object:
        return [v] if isinstance(v, str) else v

    @field_validator("tags", mode="before")
    @classmethod
    def _coerce_tags(cls, v: object) -> object:
        if isinstance(v, str):
            return [t.strip().lower() for t in v.split(",") if t.strip()]
        if isinstance(v, list):
            return [str(t).strip().lower() for t in v if str(t).strip()]
        return v

    @classmethod
    def parse_json(cls, raw: str | None) -> SearchFilters | None:
        if not raw:
            return None
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError("filters must be valid JSON") from exc
        if not isinstance(data, dict):
            raise ValueError("filters must be a JSON object")
        return cls.model_validate(data)


# Coarse MIME buckets. Prefix matching handles the long tail (`image/*`), and the
# explicit sets cover the types whose MIME strings say nothing useful.
CATEGORY_PREFIXES: dict[FileCategory, tuple[str, ...]] = {
    FileCategory.IMAGE: ("image/",),
    FileCategory.VIDEO: ("video/",),
    FileCategory.AUDIO: ("audio/",),
}

CATEGORY_EXACT: dict[FileCategory, tuple[str, ...]] = {
    FileCategory.DOCUMENT: (
        "application/pdf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/rtf",
        "application/epub+zip",
    ),
    FileCategory.ARCHIVE: (
        "application/zip",
        "application/x-tar",
        "application/gzip",
        "application/x-7z-compressed",
        "application/x-rar-compressed",
        "application/vnd.rar",
        "application/x-bzip2",
        "application/x-xz",
    ),
}

DOCUMENT_TEXT_PREFIX = "text/"
