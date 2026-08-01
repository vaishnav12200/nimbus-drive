"""Bot-token encryption at rest and secret redaction in logs."""

from __future__ import annotations

import pytest

from app.core.crypto import DecryptionError, decrypt, encrypt, generate_key
from app.core.logging import REDACTED, SENSITIVE_KEYS, _redact_secrets, hashed_user_id

TOKEN = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"


def test_round_trip() -> None:
    assert decrypt(encrypt(TOKEN)) == TOKEN


def test_ciphertext_never_contains_the_plaintext() -> None:
    assert TOKEN.encode() not in encrypt(TOKEN)


def test_encryption_is_randomised() -> None:
    """A fresh nonce per call: identical tokens must not produce identical blobs,
    or the database leaks which users share a bot."""
    assert encrypt(TOKEN) != encrypt(TOKEN)


def test_aad_binds_a_blob_to_its_owner() -> None:
    """Moving a row between users must fail loudly rather than decrypt."""
    blob = encrypt(TOKEN, aad=b"user-a")

    assert decrypt(blob, aad=b"user-a") == TOKEN
    with pytest.raises(DecryptionError):
        decrypt(blob, aad=b"user-b")
    with pytest.raises(DecryptionError):
        decrypt(blob)


def test_tampering_is_detected() -> None:
    blob = bytearray(encrypt(TOKEN))
    blob[-1] ^= 0xFF
    with pytest.raises(DecryptionError):
        decrypt(bytes(blob))


def test_truncated_ciphertext_is_rejected() -> None:
    with pytest.raises(DecryptionError):
        decrypt(b"\x01short")


def test_unknown_version_byte_is_rejected() -> None:
    blob = bytearray(encrypt(TOKEN))
    blob[0] = 0x99
    with pytest.raises(DecryptionError):
        decrypt(bytes(blob))


def test_generated_keys_are_32_bytes_of_base64() -> None:
    import base64

    assert len(base64.b64decode(generate_key())) == 32


# --- Log redaction -----------------------------------------------------


@pytest.mark.parametrize("key", sorted(SENSITIVE_KEYS))
def test_every_sensitive_key_is_scrubbed(key: str) -> None:
    event = _redact_secrets(None, "info", {key: "super-secret", "safe": "kept"})
    assert event[key] == REDACTED
    assert event["safe"] == "kept"


def test_redaction_is_case_insensitive() -> None:
    event = _redact_secrets(None, "info", {"Bot_Token": TOKEN})
    assert event["Bot_Token"] == REDACTED


def test_user_ids_are_hashed_not_logged_raw() -> None:
    import uuid

    user_id = uuid.uuid4()
    digest = hashed_user_id(user_id)

    assert str(user_id) not in digest
    assert len(digest) == 16
    assert hashed_user_id(user_id) == digest  # stable across calls
