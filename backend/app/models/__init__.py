"""SQLAlchemy models.

Every model must be imported here: Alembic autogenerate only sees tables that are
attached to ``Base.metadata`` at import time.
"""

from app.models.activity import ActivityLog
from app.models.base import Base
from app.models.enums import (
    ActivityAction,
    FileCategory,
    FileSort,
    SortOrder,
    StorageProvider,
)
from app.models.file import File, FileChunk, FileTag
from app.models.folder import Folder
from app.models.share import SharedLink
from app.models.sync import SyncTombstone
from app.models.user import RefreshToken, User, UserTelegramConfig

__all__ = [
    "ActivityAction",
    "ActivityLog",
    "Base",
    "File",
    "FileCategory",
    "FileChunk",
    "FileSort",
    "FileTag",
    "Folder",
    "RefreshToken",
    "SharedLink",
    "SortOrder",
    "StorageProvider",
    "SyncTombstone",
    "User",
    "UserTelegramConfig",
]
