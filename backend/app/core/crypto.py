"""Symmetric encryption for secrets the backend is forced to hold at rest.

Right now that is exactly one thing: the user's Telegram bot token, which the
large-file upload path needs in plaintext at request time but must never store in
plaintext (cross-cutting rule 3).

Ciphertext layout::

    b"\\x01" || nonce (12 bytes) || AES-256-GCM(ciphertext || tag)

The leading version byte exists so the key or algorithm can be rotated later
without guessing at how an old blob was produced.
"""

from __future__ import annotations

import base64
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)

VERSION = b"\x01"
NONCE_SIZE = 12  # AES-GCM's standard nonce length
KEY_SIZE = 32

# Deterministic key used only when SECRET_ENCRYPTION_KEY is unset outside
# production, so a dev restart can still read yesterday's rows. Production
# startup refuses to boot without a real key (see Settings validation).
_DEV_KEY = b"nimbus-drive-insecure-dev-key!!!"  # exactly 32 bytes
_dev_warning_emitted = False


class DecryptionError(Exception):
    """Raised when a stored blob cannot be authenticated with the current key."""


def _key() -> bytes:
    global _dev_warning_emitted
    if settings.secret_encryption_key:
        return base64.b64decode(settings.secret_encryption_key)
    if settings.is_production:  # pragma: no cover - blocked by Settings validation
        raise RuntimeError("SECRET_ENCRYPTION_KEY is required in production")
    if not _dev_warning_emitted:
        log.warning(
            "secret_encryption_key_missing",
            detail="Falling back to the insecure built-in development key. "
            "Set SECRET_ENCRYPTION_KEY before storing anything real.",
        )
        _dev_warning_emitted = True
    return _DEV_KEY


def encrypt(plaintext: str, *, aad: bytes | None = None) -> bytes:
    """Encrypt a UTF-8 secret. ``aad`` binds the blob to a context (e.g. a user id)."""
    nonce = os.urandom(NONCE_SIZE)
    ciphertext = AESGCM(_key()).encrypt(nonce, plaintext.encode("utf-8"), aad)
    return VERSION + nonce + ciphertext


def decrypt(blob: bytes, *, aad: bytes | None = None) -> str:
    """Reverse :func:`encrypt`. Raises :class:`DecryptionError` on any mismatch."""
    if len(blob) < len(VERSION) + NONCE_SIZE + 16:
        raise DecryptionError("ciphertext is too short to be well-formed")
    version, rest = blob[: len(VERSION)], blob[len(VERSION) :]
    if version != VERSION:
        raise DecryptionError(f"unsupported ciphertext version {version!r}")
    nonce, ciphertext = rest[:NONCE_SIZE], rest[NONCE_SIZE:]
    try:
        return AESGCM(_key()).decrypt(nonce, ciphertext, aad).decode("utf-8")
    except Exception as exc:
        # Wrong key, tampered blob, or wrong AAD — all indistinguishable, by design.
        raise DecryptionError("could not decrypt secret") from exc


def generate_key() -> str:
    """A fresh base64 key suitable for SECRET_ENCRYPTION_KEY."""
    return base64.b64encode(os.urandom(KEY_SIZE)).decode("ascii")
