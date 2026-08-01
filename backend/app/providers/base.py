"""The storage provider interface (spec §11)."""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Protocol, runtime_checkable


@runtime_checkable
class ByteReader(Protocol):
    """Anything that yields bytes sequentially.

    Narrower than ``BinaryIO`` on purpose: providers only ever call ``read``, and
    demanding the full file protocol would rule out the bounded slice views used
    to upload one chunk of a staged file without copying it.
    """

    def read(self, size: int = -1) -> bytes: ...


@dataclass(frozen=True)
class StorageCredentials:
    """Per-user secrets needed to talk to the backing store.

    Held in memory for the duration of one request only — the persisted form is
    always the AES-GCM ciphertext in ``user_telegram_configs``.
    """

    bot_token: str
    channel_id: int


@dataclass(frozen=True)
class StorageRef:
    """Points at stored bytes. For Telegram: a message in a channel."""

    channel_id: int
    message_id: int
    file_id: str | None = None
    file_unique_id: str | None = None


@dataclass(frozen=True)
class UploadMetadata:
    filename: str
    size: int
    mime_type: str = "application/octet-stream"
    caption: str | None = None


@dataclass(frozen=True)
class UploadResult:
    message_id: int
    size: int
    file_id: str | None = None
    file_unique_id: str | None = None


@dataclass(frozen=True)
class RemoteFileInfo:
    size: int
    exists: bool
    file_id: str | None = None
    file_unique_id: str | None = None
    mime_type: str | None = None


class StorageProvider(ABC):
    """Byte-level operations on a user's backing store.

    Implementations are stateless with respect to a *user*: credentials arrive
    with each call, so one provider instance serves every request.
    """

    name: str

    @property
    @abstractmethod
    def max_single_upload(self) -> int:
        """Largest object this provider accepts without the caller chunking it."""

    @abstractmethod
    async def upload(
        self,
        file_stream: ByteReader,
        metadata: UploadMetadata,
        credentials: StorageCredentials,
    ) -> UploadResult:
        """Store ``file_stream``'s bytes and return a reference to them."""

    @abstractmethod
    def download(
        self,
        ref: StorageRef,
        credentials: StorageCredentials,
        *,
        offset: int = 0,
        limit: int | None = None,
    ) -> AsyncIterator[bytes]:
        """Yield the stored bytes, optionally a sub-range.

        ``offset``/``limit`` are byte positions within *this object*, which is
        what makes HTTP Range support possible without downloading the whole file.
        """

    @abstractmethod
    async def delete(self, ref: StorageRef, credentials: StorageCredentials) -> None:
        """Remove the stored bytes. Must be idempotent."""

    @abstractmethod
    async def get_info(
        self, ref: StorageRef, credentials: StorageCredentials
    ) -> RemoteFileInfo:
        """Describe the stored object without transferring it."""
