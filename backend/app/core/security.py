"""Password hashing and token issuance.

**Access tokens** are RS256 JWTs carrying ``sub``, ``email``, ``iat``, ``exp``,
``jti`` (spec §9.1) and expire in 15 minutes.

**Refresh tokens** are *not* JWTs. They are 48 bytes of CSPRNG output, stored
server-side as a SHA-256 digest. A refresh token has to be revocable the instant
reuse is detected, and a self-contained JWT cannot be — it would need the same
server-side lookup anyway, minus the property that a stolen database dump yields
no usable credentials.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError

from app.core.config import settings
from app.core.errors import InvalidTokenError
from app.core.logging import get_logger

log = get_logger(__name__)

ACCESS_TOKEN_TYPE = "access"
REFRESH_TOKEN_BYTES = 48


# --- Passwords ---------------------------------------------------------

_hasher = PasswordHasher(
    time_cost=settings.argon2_time_cost,
    memory_cost=settings.argon2_memory_cost,
    parallelism=settings.argon2_parallelism,
)


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password: str, password_hash: str | None) -> bool:
    """Constant-ish time check that tolerates a missing hash (OAuth-only accounts)."""
    if not password_hash:
        # Still burn a hash cycle so "no password set" and "wrong password" do not
        # differ in response time.
        _hasher.hash(password)
        return False
    try:
        return _hasher.verify(password_hash, password)
    except Exception:
        return False


def needs_rehash(password_hash: str) -> bool:
    try:
        return _hasher.check_needs_rehash(password_hash)
    except InvalidHashError:  # pragma: no cover - corrupt row
        return True


# --- JWT keys ----------------------------------------------------------


@dataclass(frozen=True)
class KeyPair:
    private_pem: str
    public_pem: str


def _generate_dev_keypair() -> KeyPair:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    public_pem = (
        key.public_key()
        .public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        .decode()
    )
    return KeyPair(private_pem, public_pem)


def _load_keypair() -> KeyPair:
    if settings.jwt_private_key and settings.jwt_public_key:
        return KeyPair(settings.jwt_private_key, settings.jwt_public_key)

    if settings.is_production:  # pragma: no cover - blocked by Settings validation
        raise RuntimeError(
            "JWT_PRIVATE_KEY and JWT_PUBLIC_KEY are required in production"
        )

    # Dev/test: persist a generated keypair so tokens survive a reload.
    cache_dir = Path(settings.temp_dir) / "dev-keys"
    private_path, public_path = cache_dir / "jwt.pem", cache_dir / "jwt.pub"
    if private_path.exists() and public_path.exists():
        return KeyPair(private_path.read_text(), public_path.read_text())

    pair = _generate_dev_keypair()
    cache_dir.mkdir(parents=True, exist_ok=True)
    private_path.write_text(pair.private_pem)
    private_path.chmod(0o600)
    public_path.write_text(pair.public_pem)
    log.warning(
        "jwt_dev_keypair_generated",
        path=str(cache_dir),
        detail="Generated an ephemeral RSA keypair. Set JWT_PRIVATE_KEY/JWT_PUBLIC_KEY "
        "for anything beyond local development.",
    )
    return pair


_keypair: KeyPair | None = None


def keypair() -> KeyPair:
    global _keypair
    if _keypair is None:
        _keypair = _load_keypair()
    return _keypair


# --- Access tokens -----------------------------------------------------


@dataclass(frozen=True)
class IssuedToken:
    token: str
    jti: uuid.UUID
    expires_at: datetime

    @property
    def expires_in(self) -> int:
        return max(0, int((self.expires_at - datetime.now(UTC)).total_seconds()))


def create_access_token(
    *, user_id: uuid.UUID, email: str, extra_claims: dict[str, Any] | None = None
) -> IssuedToken:
    now = datetime.now(UTC)
    expires_at = now + timedelta(minutes=settings.access_token_ttl_minutes)
    jti = uuid.uuid4()
    claims: dict[str, Any] = {
        "sub": str(user_id),
        "email": email,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
        "jti": str(jti),
        "iss": settings.jwt_issuer,
        "typ": ACCESS_TOKEN_TYPE,
        **(extra_claims or {}),
    }
    token = jwt.encode(claims, keypair().private_pem, algorithm=settings.jwt_algorithm)
    return IssuedToken(token=token, jti=jti, expires_at=expires_at)


def decode_access_token(token: str) -> dict[str, Any]:
    """Verify signature, expiry and issuer. Raises :class:`InvalidTokenError`."""
    try:
        claims: dict[str, Any] = jwt.decode(
            token,
            keypair().public_pem,
            algorithms=[settings.jwt_algorithm],
            issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "sub", "jti"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise InvalidTokenError("The access token has expired") from exc
    except jwt.InvalidTokenError as exc:
        raise InvalidTokenError() from exc

    if claims.get("typ") != ACCESS_TOKEN_TYPE:
        raise InvalidTokenError("Expected an access token")
    return claims


# --- Refresh tokens ----------------------------------------------------


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(REFRESH_TOKEN_BYTES)


def hash_refresh_token(token: str) -> str:
    """SHA-256 hex digest. A fast hash is correct here: the input is already
    48 bytes of full-entropy randomness, so there is nothing to brute-force."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_share_token() -> str:
    """URL-safe token for a public share link (≥ 32 bytes of entropy)."""
    return secrets.token_urlsafe(32)
