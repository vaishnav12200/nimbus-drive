"""File schemas."""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.models.enums import StorageProvider
from app.schemas.folder import validate_name

MAX_TAGS = 32
SHA256_LENGTH = 64


def _normalize_tags(tags: list[str] | None) -> list[str] | None:
    if tags is None:
        return None
    cleaned = {t.strip().lower() for t in tags if t and t.strip()}
    if len(cleaned) > MAX_TAGS:
        raise ValueError(f"a file can carry at most {MAX_TAGS} tags")
    if any(len(t) > 64 for t in cleaned):
        raise ValueError("each tag must be 64 characters or fewer")
    return sorted(cleaned)


class FileCreate(BaseModel):
    """Metadata for a file the *client* already uploaded to Telegram (≤ 20 MB).

    `telegram_channel_id` is intentionally absent: it is read from the caller's
    active binding, so a client cannot claim a file lives in someone else's
    channel.
    """

    name: str = Field(..., min_length=1, max_length=255)
    original_name: str | None = Field(default=None, max_length=255)
    size: int = Field(..., ge=0)
    mime_type: str = Field(default="application/octet-stream", max_length=255)
    sha256: str | None = Field(
        default=None, min_length=SHA256_LENGTH, max_length=SHA256_LENGTH
    )
    folder_id: uuid.UUID | None = None

    telegram_message_id: int = Field(..., gt=0)
    telegram_file_id: str | None = None
    telegram_file_unique_id: str | None = Field(default=None, max_length=64)

    is_encrypted: bool = False
    tags: list[str] | None = None

    _validate_name = field_validator("name")(validate_name)

    @field_validator("sha256")
    @classmethod
    def _validate_sha256(cls, v: str | None) -> str | None:
        if v is None:
            return None
        v = v.strip().lower()
        if not all(c in "0123456789abcdef" for c in v):
            raise ValueError("sha256 must be a hex digest")
        return v

    @field_validator("tags")
    @classmethod
    def _validate_tags(cls, v: list[str] | None) -> list[str] | None:
        return _normalize_tags(v)

    @model_validator(mode="after")
    def _default_original_name(self) -> FileCreate:
        if not self.original_name:
            object.__setattr__(self, "original_name", self.name)
        return self


class FileReserve(BaseModel):
    """Reserve a metadata row *before* streaming a large file to the backend.

    Large uploads are two requests — `POST /api/files/reserve` then
    `POST /api/files/{id}/upload` — so the client has an id to attach progress
    and retries to before a single byte has moved.
    """

    name: str = Field(..., min_length=1, max_length=255)
    size: int = Field(..., gt=0)
    mime_type: str = Field(default="application/octet-stream", max_length=255)
    sha256: str | None = Field(
        default=None, min_length=SHA256_LENGTH, max_length=SHA256_LENGTH
    )
    folder_id: uuid.UUID | None = None
    is_encrypted: bool = False
    tags: list[str] | None = None

    _validate_name = field_validator("name")(validate_name)

    @field_validator("tags")
    @classmethod
    def _validate_tags(cls, v: list[str] | None) -> list[str] | None:
        return _normalize_tags(v)


class FileUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=255)
    folder_id: uuid.UUID | None = None
    is_favorite: bool | None = None
    tags: list[str] | None = None

    @field_validator("name")
    @classmethod
    def _validate_name(cls, v: str | None) -> str | None:
        return validate_name(v) if v is not None else None

    @field_validator("tags")
    @classmethod
    def _validate_tags(cls, v: list[str] | None) -> list[str] | None:
        return _normalize_tags(v)


class FileTarget(BaseModel):
    target_folder_id: uuid.UUID | None = Field(
        default=None, description="Null moves the file to the root"
    )


class FileCopy(FileTarget):
    name: str | None = Field(
        default=None, max_length=255, description="Defaults to 'name (copy)'"
    )


class ChunkOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    chunk_index: int
    size: int
    offset: int
    telegram_message_id: int


class FileOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    original_name: str
    size: int
    mime_type: str
    sha256: str | None
    folder_id: uuid.UUID | None
    storage_provider: StorageProvider

    telegram_message_id: int | None
    telegram_file_id: str | None
    telegram_channel_id: int | None

    is_chunked: bool
    chunk_count: int
    is_encrypted: bool
    is_favorite: bool
    is_deleted: bool
    deleted_at: datetime | None

    tags: list[str] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime

    @classmethod
    def from_model(cls, file: object) -> FileOut:
        data = {
            field: getattr(file, field)
            for field in cls.model_fields
            if field != "tags" and hasattr(file, field)
        }
        data["tags"] = getattr(file, "tag_names", [])
        return cls.model_validate(data)


class FileDetailOut(FileOut):
    chunks: list[ChunkOut] = Field(default_factory=list)

    @classmethod
    def from_model(cls, file: object) -> FileDetailOut:
        base = FileOut.from_model(file).model_dump()
        base["chunks"] = [
            ChunkOut.model_validate(c) for c in getattr(file, "chunks", []) or []
        ]
        return cls.model_validate(base)


class DedupHit(BaseModel):
    """Answer to 'have I already uploaded these bytes?'."""

    found: bool
    file_id: uuid.UUID | None = None
    name: str | None = None
    size: int | None = None


class DownloadTicket(BaseModel):
    """How to fetch a file's bytes.

    `mode="direct"` means the client can pull straight from Telegram — it already
    holds the bot token, so it builds
    `https://api.telegram.org/file/bot<token>/<telegram_file_path>` itself and the
    bytes never touch this server. The token is deliberately not part of this
    response; `telegram_file_path` alone is useless without it.

    `mode="proxy"` means Telegram will not serve the object directly (it is
    chunked, or larger than the Bot API's 20 MB download ceiling), so the client
    must stream it from `proxy_url` on this API.
    """

    mode: str = Field(..., examples=["direct", "proxy"])
    proxy_url: str = Field(..., description="Always available; requires the bearer token")
    telegram_file_path: str | None = None
    size: int
    mime_type: str
    name: str
    is_encrypted: bool
    is_chunked: bool
