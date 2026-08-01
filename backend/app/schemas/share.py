"""Share link schemas."""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

MAX_EXPIRY_SECONDS = 365 * 24 * 3600


class ShareCreate(BaseModel):
    file_id: uuid.UUID
    expires_in: int | None = Field(
        default=None,
        gt=0,
        le=MAX_EXPIRY_SECONDS,
        description="Seconds until the link expires; omit for no expiry",
    )
    max_downloads: int | None = Field(
        default=None, gt=0, description="Revoke the link after this many downloads"
    )
    password: str | None = Field(
        default=None,
        min_length=4,
        max_length=256,
        description="Optional passphrase the recipient must supply",
    )


class ShareOut(BaseModel):
    """The owner's view of a link — includes the token so it can be copied."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    file_id: uuid.UUID
    token: str
    expires_at: datetime | None
    max_downloads: int | None
    download_count: int
    requires_password: bool
    revoked_at: datetime | None
    created_at: datetime

    file_name: str | None = None
    file_size: int | None = None


class PublicShareOut(BaseModel):
    """What an unauthenticated visitor is allowed to learn about a link.

    Deliberately narrow: the file's name, size and type, and nothing that would
    identify the owner, their other files, or where this one sits in their tree.
    """

    name: str
    size: int
    mime_type: str
    is_encrypted: bool
    requires_password: bool
    expires_at: datetime | None
    downloads_remaining: int | None
