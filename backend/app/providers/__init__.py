"""Storage provider abstraction.

Telegram is the only implementation today, but every call site goes through
:class:`~app.providers.base.StorageProvider` so `S3Storage`, `LocalStorage` or
`IPFSStorage` can be added without touching the API layer.
"""

from app.providers.base import (
    RemoteFileInfo,
    StorageCredentials,
    StorageProvider,
    StorageRef,
    UploadResult,
)
from app.providers.registry import get_provider, register_provider

__all__ = [
    "RemoteFileInfo",
    "StorageCredentials",
    "StorageProvider",
    "StorageRef",
    "UploadResult",
    "get_provider",
    "register_provider",
]
