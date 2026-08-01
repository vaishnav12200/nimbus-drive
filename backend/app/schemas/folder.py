"""Folder schemas."""

from __future__ import annotations

import re
import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

HEX_COLOR = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
# `/` would break the materialized path; the rest are reserved on the platforms
# the mobile client writes cached copies to.
ILLEGAL_NAME_CHARS = re.compile(r'[/\\:*?"<>|\x00-\x1f]')


def validate_name(value: str) -> str:
    name = value.strip()
    if not name:
        raise ValueError("name must not be empty")
    if name in {".", ".."}:
        raise ValueError("name must not be '.' or '..'")
    if ILLEGAL_NAME_CHARS.search(name):
        raise ValueError('name must not contain / \\ : * ? " < > | or control characters')
    return name


class FolderCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    parent_id: uuid.UUID | None = Field(
        default=None, description="Omit or null to create at the root"
    )
    color: str | None = Field(default=None, examples=["#4F46E5"])

    _validate_name = field_validator("name")(validate_name)

    @field_validator("color")
    @classmethod
    def _validate_color(cls, v: str | None) -> str | None:
        if v is not None and not HEX_COLOR.match(v):
            raise ValueError("color must be a hex value like #4F46E5")
        return v


class FolderUpdate(BaseModel):
    """All fields optional; only what is supplied is changed.

    `parent_id` is deliberately part of the update payload so a rename and a move
    can be one atomic request — the path recomputation is identical either way.
    """

    name: str | None = Field(default=None, min_length=1, max_length=255)
    color: str | None = None
    parent_id: uuid.UUID | None = None

    @field_validator("name")
    @classmethod
    def _validate_name(cls, v: str | None) -> str | None:
        return validate_name(v) if v is not None else None

    @field_validator("color")
    @classmethod
    def _validate_color(cls, v: str | None) -> str | None:
        if v is not None and v != "" and not HEX_COLOR.match(v):
            raise ValueError("color must be a hex value like #4F46E5")
        return v


class FolderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    parent_id: uuid.UUID | None
    path: str
    color: str | None
    created_at: datetime
    updated_at: datetime


class FolderDetailOut(FolderOut):
    """A folder plus the counts and breadcrumb trail the UI needs to render it."""

    breadcrumbs: list[FolderBreadcrumb] = Field(default_factory=list)
    subfolder_count: int = 0
    file_count: int = 0


class FolderBreadcrumb(BaseModel):
    id: uuid.UUID
    name: str


FolderDetailOut.model_rebuild()
