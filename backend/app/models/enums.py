"""Enumerations stored as short strings.

Deliberately not PostgreSQL ENUM types: adding a value to a PG enum needs a
migration and an exclusive lock, and these sets are expected to grow (new storage
providers, new audited actions).
"""

from __future__ import annotations

from enum import StrEnum


class StorageProvider(StrEnum):
    TELEGRAM = "telegram"
    S3 = "s3"
    LOCAL = "local"
    IPFS = "ipfs"


class ActivityAction(StrEnum):
    UPLOAD = "upload"
    DOWNLOAD = "download"
    STREAM = "stream"
    RENAME = "rename"
    MOVE = "move"
    COPY = "copy"
    DELETE = "delete"
    RESTORE = "restore"
    PURGE = "purge"
    FAVORITE = "favorite"
    UNFAVORITE = "unfavorite"
    SHARE_CREATE = "share_create"
    SHARE_REVOKE = "share_revoke"
    SHARE_DOWNLOAD = "share_download"
    FOLDER_CREATE = "folder_create"
    FOLDER_RENAME = "folder_rename"
    FOLDER_MOVE = "folder_move"
    FOLDER_DELETE = "folder_delete"
    LOGIN = "login"
    LOGOUT = "logout"
    TELEGRAM_BIND = "telegram_bind"
    TELEGRAM_TEST = "telegram_test"


class FileSort(StrEnum):
    NAME = "name"
    SIZE = "size"
    CREATED_AT = "created_at"
    UPDATED_AT = "updated_at"


class SortOrder(StrEnum):
    ASC = "asc"
    DESC = "desc"


class FileCategory(StrEnum):
    """Coarse MIME grouping used by the search `type` filter."""

    IMAGE = "image"
    VIDEO = "video"
    AUDIO = "audio"
    DOCUMENT = "document"
    ARCHIVE = "archive"
    OTHER = "other"
