"""Telegram storage: Bot API for small objects, MTProto for everything else.

Two transports, because Telegram gives us no choice:

* **Bot API** (`api.telegram.org`) is simple HTTPS but caps both uploads and
  *downloads* at 20 MB.
* **MTProto** (via Telethon) reaches Telegram's 2 GB per-file ceiling and is the
  only transport that can serve an arbitrary byte range, which is what makes
  video seeking work.

Which one a call uses is decided by size, not by preference.
"""

from __future__ import annotations

import re
from collections.abc import AsyncIterator
from typing import Any

import httpx

from app.core.config import settings
from app.core.errors import (
    PayloadTooLargeError,
    TelegramError,
    TelegramFloodWaitError,
)
from app.core.logging import get_logger
from app.providers.base import (
    ByteReader,
    RemoteFileInfo,
    StorageCredentials,
    StorageProvider,
    StorageRef,
    UploadMetadata,
    UploadResult,
)
from app.services.telegram_sessions import session_pool

log = get_logger(__name__)

# MTProto requires file offsets to be 4 KiB-aligned; sub-chunk precision is
# recovered by trimming the first partial block after the fact.
MTPROTO_BLOCK = 4096
STREAM_CHUNK = 256 * 1024


class TelegramStorage(StorageProvider):
    name = "telegram"

    @property
    def max_single_upload(self) -> int:
        return settings.telegram_max_file_size

    # --- Bot API plumbing ---------------------------------------------

    @staticmethod
    def _api_url(token: str, method: str) -> str:
        return f"{settings.telegram_bot_api_base}/bot{token}/{method}"

    @staticmethod
    def _file_url(token: str, file_path: str) -> str:
        return f"{settings.telegram_bot_api_base}/file/bot{token}/{file_path}"

    @staticmethod
    def _raise_for_telegram(payload: dict[str, Any], status_code: int) -> None:
        """Map a Bot API failure onto a typed, actionable error (spec §16.2)."""
        description = str(payload.get("description", "")) or "Telegram rejected the call"
        lowered = description.lower()

        retry_after = (payload.get("parameters") or {}).get("retry_after")
        if status_code == 429 or retry_after:
            raise TelegramFloodWaitError(int(retry_after or 30))

        if "too big" in lowered or "too large" in lowered or status_code == 413:
            raise PayloadTooLargeError(
                "Telegram rejected the file as too large",
                details={"description": description},
            )
        if "blocked" in lowered:
            raise TelegramError(
                "The bot has been blocked; unblock it in Telegram and retry",
                code="BOT_BLOCKED",
            )
        if "chat not found" in lowered or "peer_id_invalid" in lowered:
            raise TelegramError(
                "The channel could not be found. Check the channel ID and that "
                "the bot is still a member.",
                code="CHANNEL_INVALID",
            )
        if "not enough rights" in lowered or "chat_write_forbidden" in lowered:
            raise TelegramError(
                "The bot is not allowed to post in this channel; add it as an "
                "administrator.",
                code="CHAT_WRITE_FORBIDDEN",
            )
        if status_code == 401 or "unauthorized" in lowered:
            raise TelegramError(
                "The bot token is invalid or has been revoked",
                code="BOT_TOKEN_INVALID",
            )

        raise TelegramError(description, details={"telegram_status": status_code})

    @classmethod
    async def call(
        cls,
        token: str,
        method: str,
        *,
        data: dict[str, Any] | None = None,
        files: dict[str, Any] | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        """Invoke one Bot API method and unwrap its `result`."""
        url = cls._api_url(token, method)
        request_timeout = httpx.Timeout(timeout or settings.telegram_request_timeout)
        try:
            async with httpx.AsyncClient(timeout=request_timeout) as client:
                response = await client.post(url, data=data, files=files)
        except httpx.HTTPError as exc:
            log.warning("telegram_http_error", method=method, error=type(exc).__name__)
            raise TelegramError(
                "Could not reach Telegram", code="TELEGRAM_UNREACHABLE"
            ) from exc

        try:
            payload = response.json()
        except ValueError as exc:
            raise TelegramError("Telegram returned a malformed response") from exc

        if not payload.get("ok"):
            cls._raise_for_telegram(payload, response.status_code)
        return dict(payload.get("result") or {})

    # --- Upload --------------------------------------------------------

    async def upload(
        self,
        file_stream: ByteReader,
        metadata: UploadMetadata,
        credentials: StorageCredentials,
    ) -> UploadResult:
        if metadata.size > settings.telegram_max_file_size:
            raise PayloadTooLargeError(
                "Telegram caps a single file at 2 GB",
                details={"size": metadata.size, "limit": settings.telegram_max_file_size},
            )
        if metadata.size <= settings.telegram_bot_api_max_upload:
            return await self._upload_bot_api(file_stream, metadata, credentials)
        return await self._upload_mtproto(file_stream, metadata, credentials)

    async def _upload_bot_api(
        self,
        file_stream: ByteReader,
        metadata: UploadMetadata,
        credentials: StorageCredentials,
    ) -> UploadResult:
        result = await self.call(
            credentials.bot_token,
            "sendDocument",
            data={
                "chat_id": str(credentials.channel_id),
                "disable_notification": "true",
                **({"caption": metadata.caption} if metadata.caption else {}),
            },
            files={
                "document": (
                    metadata.filename,
                    file_stream,
                    metadata.mime_type or "application/octet-stream",
                )
            },
        )
        document = result.get("document") or {}
        return UploadResult(
            message_id=int(result["message_id"]),
            size=int(document.get("file_size") or metadata.size),
            file_id=document.get("file_id"),
            file_unique_id=document.get("file_unique_id"),
        )

    async def _upload_mtproto(
        self,
        file_stream: ByteReader,
        metadata: UploadMetadata,
        credentials: StorageCredentials,
    ) -> UploadResult:
        from telethon.errors import FloodWaitError

        client = await session_pool.acquire(credentials.bot_token)
        peer = await self._resolve_peer(client, credentials.channel_id)

        try:
            handle = await client.upload_file(
                file_stream,
                file_size=metadata.size,
                file_name=metadata.filename,
            )
            message = await client.send_file(
                peer,
                handle,
                file_name=metadata.filename,
                force_document=True,
                caption=metadata.caption or "",
                silent=True,
            )
        except FloodWaitError as exc:
            raise TelegramFloodWaitError(int(exc.seconds)) from exc
        except Exception as exc:
            log.warning("mtproto_upload_failed", error=type(exc).__name__)
            raise TelegramError(
                "Telegram rejected the upload", code="MTPROTO_UPLOAD_FAILED"
            ) from exc

        document = getattr(message, "document", None)
        return UploadResult(
            message_id=int(message.id),
            size=int(getattr(document, "size", None) or metadata.size),
            file_id=None,  # MTProto file references are not Bot API file_ids
            file_unique_id=None,
        )

    # --- Download ------------------------------------------------------

    async def download(  # type: ignore[override]
        self,
        ref: StorageRef,
        credentials: StorageCredentials,
        *,
        offset: int = 0,
        limit: int | None = None,
    ) -> AsyncIterator[bytes]:
        """Stream bytes, preferring the Bot API when the object is small enough.

        ``file_id`` is only present for Bot API uploads, and those are ≤ 20 MB by
        construction, so its presence is a sufficient signal that the cheap path
        will work.
        """
        if ref.file_id:
            try:
                async for chunk in self._download_bot_api(
                    ref, credentials, offset=offset, limit=limit
                ):
                    yield chunk
                return
            except TelegramError as exc:
                # A file_id can expire or the object can outgrow the Bot API's
                # download limit; fall through rather than failing the request.
                log.info(
                    "bot_api_download_fallback",
                    code=exc.code,
                    message_id=ref.message_id,
                )

        async for chunk in self._download_mtproto(
            ref, credentials, offset=offset, limit=limit
        ):
            yield chunk

    async def _download_bot_api(
        self,
        ref: StorageRef,
        credentials: StorageCredentials,
        *,
        offset: int,
        limit: int | None,
    ) -> AsyncIterator[bytes]:
        meta = await self.call(
            credentials.bot_token, "getFile", data={"file_id": ref.file_id}
        )
        file_path = meta.get("file_path")
        if not file_path:
            raise TelegramError("Telegram did not return a file path")

        url = self._file_url(credentials.bot_token, file_path)
        headers: dict[str, str] = {}
        if offset or limit is not None:
            end = "" if limit is None else str(offset + limit - 1)
            headers["Range"] = f"bytes={offset}-{end}"

        timeout = httpx.Timeout(settings.telegram_request_timeout, read=None)
        async with (
            httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client,
            client.stream("GET", url, headers=headers) as response,
        ):
            if response.status_code >= 400:
                raise TelegramError(
                    "Telegram refused the file download",
                    code="FILE_DOWNLOAD_FAILED",
                    details={"telegram_status": response.status_code},
                )

            # If the server ignored our Range header we must trim locally,
            # otherwise the caller silently receives the wrong bytes.
            skip = offset if (headers and response.status_code == 200) else 0
            remaining = limit
            async for chunk in response.aiter_bytes(STREAM_CHUNK):
                if skip:
                    if len(chunk) <= skip:
                        skip -= len(chunk)
                        continue
                    chunk, skip = chunk[skip:], 0
                if remaining is not None:
                    if len(chunk) >= remaining:
                        yield chunk[:remaining]
                        return
                    remaining -= len(chunk)
                yield chunk

    async def _download_mtproto(
        self,
        ref: StorageRef,
        credentials: StorageCredentials,
        *,
        offset: int,
        limit: int | None,
    ) -> AsyncIterator[bytes]:
        from telethon.errors import FloodWaitError

        client = await session_pool.acquire(credentials.bot_token)
        message = await self._get_message(client, credentials.channel_id, ref.message_id)
        media = getattr(message, "document", None) or getattr(message, "media", None)
        if media is None:
            raise TelegramError(
                "The Telegram message no longer carries a file",
                code="REMOTE_FILE_MISSING",
            )

        # MTProto only accepts 4 KiB-aligned offsets, so start at the block that
        # contains `offset` and discard the leading bytes we did not ask for.
        aligned = (offset // MTPROTO_BLOCK) * MTPROTO_BLOCK
        skip = offset - aligned
        remaining = limit

        try:
            async for block in client.iter_download(
                media, offset=aligned, request_size=STREAM_CHUNK
            ):
                chunk = bytes(block)
                if skip:
                    if len(chunk) <= skip:
                        skip -= len(chunk)
                        continue
                    chunk, skip = chunk[skip:], 0
                if remaining is not None:
                    if len(chunk) >= remaining:
                        yield chunk[:remaining]
                        return
                    remaining -= len(chunk)
                yield chunk
        except FloodWaitError as exc:
            raise TelegramFloodWaitError(int(exc.seconds)) from exc
        except Exception as exc:
            log.warning("mtproto_download_failed", error=type(exc).__name__)
            raise TelegramError(
                "Telegram refused the download", code="MTPROTO_DOWNLOAD_FAILED"
            ) from exc

    # --- Delete / info -------------------------------------------------

    async def delete(self, ref: StorageRef, credentials: StorageCredentials) -> None:
        """Delete the backing message. Idempotent: an already-gone message is fine."""
        try:
            await self.call(
                credentials.bot_token,
                "deleteMessage",
                data={
                    "chat_id": str(ref.channel_id),
                    "message_id": str(ref.message_id),
                },
            )
        except TelegramError as exc:
            if exc.code in {"CHANNEL_INVALID"} or "not found" in exc.message.lower():
                log.info("telegram_delete_noop", message_id=ref.message_id)
                return
            raise

    async def get_info(
        self, ref: StorageRef, credentials: StorageCredentials
    ) -> RemoteFileInfo:
        if ref.file_id:
            try:
                meta = await self.call(
                    credentials.bot_token, "getFile", data={"file_id": ref.file_id}
                )
                return RemoteFileInfo(
                    size=int(meta.get("file_size") or 0),
                    exists=True,
                    file_id=ref.file_id,
                    file_unique_id=ref.file_unique_id,
                )
            except TelegramError:
                pass  # fall through to MTProto, which sees the message directly

        client = await session_pool.acquire(credentials.bot_token)
        try:
            message = await self._get_message(
                client, credentials.channel_id, ref.message_id
            )
        except TelegramError:
            return RemoteFileInfo(size=0, exists=False)

        document = getattr(message, "document", None)
        return RemoteFileInfo(
            size=int(getattr(document, "size", 0) or 0),
            exists=document is not None,
            mime_type=getattr(document, "mime_type", None),
        )

    # --- Telethon helpers ----------------------------------------------

    @staticmethod
    async def _resolve_peer(client: Any, channel_id: int) -> Any:
        """Get an input peer for a channel the bot administrates.

        Bots have no dialog list, so Telethon often cannot resolve a bare channel
        id from cache. Telegram accepts ``access_hash=0`` from a bot for a channel
        it belongs to, which is the documented way out of that.
        """
        from telethon import utils
        from telethon.tl.types import InputPeerChannel

        try:
            return await client.get_input_entity(channel_id)
        except (ValueError, TypeError):
            internal_id, _ = utils.resolve_id(channel_id)
            return InputPeerChannel(internal_id, 0)

    @classmethod
    async def _get_message(cls, client: Any, channel_id: int, message_id: int) -> Any:
        """Fetch one message by id.

        Bots cannot browse channel history, but fetching an explicit id works —
        which is exactly why every file row stores its `telegram_message_id`.
        """
        peer = await cls._resolve_peer(client, channel_id)
        try:
            message = await client.get_messages(peer, ids=message_id)
        except Exception as exc:
            log.warning("mtproto_get_message_failed", error=type(exc).__name__)
            raise TelegramError(
                "Could not read the Telegram message", code="MESSAGE_FETCH_FAILED"
            ) from exc

        if message is None:
            raise TelegramError(
                "The Telegram message no longer exists. It may have been deleted "
                "directly in the channel.",
                code="MESSAGE_DELETED",
            )
        return message


BOT_TOKEN_PATTERN = re.compile(r"^\d{5,}:[A-Za-z0-9_-]{30,}$")


def looks_like_bot_token(token: str) -> bool:
    """Cheap shape check so an obviously wrong paste fails before a network call."""
    return bool(BOT_TOKEN_PATTERN.match(token.strip()))
