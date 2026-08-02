"""Client-side encryption schemas (spec §9.2).

The backend's whole role here is custody of the *public* parameters needed to
re-derive a key on another device: the salt, the KDF, its cost parameters, and
an opaque verifier blob. It never sees the password, the key, or plaintext.

It does enforce a floor on the cost parameters. A client is free to choose its
KDF — it knows what its crypto library can do — but not to choose one so weak
that the ciphertext is trivially attackable, because the user has no way to tell
and no way to recover.
"""

from __future__ import annotations

import base64
from datetime import datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, Field, field_validator, model_validator

SALT_BYTES = 32
MAX_VERIFIER_BYTES = 1024


class Kdf(StrEnum):
    ARGON2ID = "argon2id"
    PBKDF2_SHA256 = "pbkdf2-sha256"


# OWASP Password Storage Cheat Sheet minimums. The spec's 100_000 PBKDF2
# iterations is roughly a sixth of current guidance, and this protects a whole
# drive with no recovery path — so it is rejected rather than quietly accepted.
MINIMUMS: dict[Kdf, dict[str, int]] = {
    Kdf.ARGON2ID: {"memory_kib": 19456, "iterations": 2, "parallelism": 1},
    Kdf.PBKDF2_SHA256: {"iterations": 600_000},
}

# What a client should use absent a reason to differ. Argon2id at 64 MiB is
# comfortable on a mid-range phone and memory-hard, which PBKDF2 is not.
RECOMMENDED: dict[Kdf, dict[str, int]] = {
    Kdf.ARGON2ID: {"memory_kib": 65536, "iterations": 3, "parallelism": 1},
    Kdf.PBKDF2_SHA256: {"iterations": 600_000},
}

# AES-GCM's standard nonce is 96 bits. The spec said 16 bytes; anything other
# than 12 forces libraries into an extra GHASH derivation and interoperates
# badly, for no security gain.
IV_BYTES = 12


class EncryptionSetupIn(BaseModel):
    """Enable client-side encryption for this account."""

    kdf: Kdf = Kdf.ARGON2ID
    kdf_params: dict[str, int] | None = Field(
        default=None,
        description="Cost parameters. Omit to accept the recommended set.",
        examples=[{"memory_kib": 65536, "iterations": 3, "parallelism": 1}],
    )
    verifier: str | None = Field(
        default=None,
        description=(
            "Base64 of AES-256-GCM(known plaintext) under the derived key, IV "
            "prepended. Lets a new device reject a wrong password before "
            "downloading anything. Opaque to the server."
        ),
    )

    @field_validator("verifier")
    @classmethod
    def _validate_verifier(cls, v: str | None) -> str | None:
        if v is None:
            return None
        try:
            raw = base64.b64decode(v, validate=True)
        except Exception as exc:
            raise ValueError("verifier must be base64") from exc
        if not raw:
            raise ValueError("verifier must not be empty")
        if len(raw) > MAX_VERIFIER_BYTES:
            raise ValueError(f"verifier must be at most {MAX_VERIFIER_BYTES} bytes")
        if len(raw) <= IV_BYTES + 16:
            raise ValueError(
                f"verifier is too short to be a {IV_BYTES}-byte IV plus "
                "ciphertext and a 16-byte GCM tag"
            )
        return v

    @model_validator(mode="after")
    def _apply_and_check_params(self) -> EncryptionSetupIn:
        params = dict(self.kdf_params or RECOMMENDED[self.kdf])

        missing = set(MINIMUMS[self.kdf]) - set(params)
        if missing:
            raise ValueError(
                f"{self.kdf} requires {sorted(MINIMUMS[self.kdf])}; "
                f"missing {sorted(missing)}"
            )

        weak = {
            name: (params[name], floor)
            for name, floor in MINIMUMS[self.kdf].items()
            if params[name] < floor
        }
        if weak:
            detail = ", ".join(
                f"{name}={got} (minimum {floor})" for name, (got, floor) in weak.items()
            )
            raise ValueError(
                f"KDF parameters are below the accepted minimum: {detail}. "
                "These protect data that cannot be recovered if the password "
                "is brute-forced."
            )

        object.__setattr__(self, "kdf_params", params)
        return self


class EncryptionOut(BaseModel):
    """Everything a client needs to re-derive its key — and nothing more."""

    enabled: bool
    kdf: Kdf | None = None
    kdf_params: dict[str, Any] | None = None
    salt: str | None = Field(default=None, description="Base64, 32 bytes")
    verifier: str | None = Field(default=None, description="Base64, or null if unset")
    iv_bytes: int = Field(
        default=IV_BYTES,
        description="IV length the client must use for AES-256-GCM",
    )
    encrypted_file_count: int = Field(
        default=0, description="Files currently stored encrypted under this key"
    )
    enabled_at: datetime | None = None


class EncryptionRecommendationOut(BaseModel):
    """Advertises the parameters to use, so a client need not hard-code them."""

    kdf: Kdf
    kdf_params: dict[str, int]
    minimums: dict[str, int]
    iv_bytes: int = IV_BYTES
    salt_bytes: int = SALT_BYTES
    cipher: str = "AES-256-GCM"
