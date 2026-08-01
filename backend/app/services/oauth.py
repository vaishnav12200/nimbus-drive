"""Google and GitHub sign-in.

Both flows end at the same place: a *verified* provider user id and email address,
which :func:`app.services.auth.upsert_oauth_user` turns into a local account.

Verification is done properly — the Google ID token's signature is checked against
Google's published JWKS rather than trusting the client's decoding of it, because
an unverified `id_token` is just an attacker-supplied JSON blob.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

import httpx
import jwt
from jwt import PyJWKClient

from app.core.config import settings
from app.core.errors import AuthenticationError, BadRequestError, ServiceUnavailableError
from app.core.logging import get_logger

log = get_logger(__name__)

GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = ("https://accounts.google.com", "accounts.google.com")
GITHUB_TOKEN_URL = "https://github.com/login/oauth/access_token"
GITHUB_USER_URL = "https://api.github.com/user"
GITHUB_EMAILS_URL = "https://api.github.com/user/emails"

_HTTP_TIMEOUT = httpx.Timeout(10.0)


@dataclass(frozen=True)
class OAuthIdentity:
    provider: str
    provider_user_id: str
    email: str
    display_name: str | None


# PyJWKClient caches the key set and refreshes on an unknown `kid`, so this is
# one network call per key rotation rather than one per login.
_google_jwks: PyJWKClient | None = None


def _jwks_client() -> PyJWKClient:
    global _google_jwks
    if _google_jwks is None:
        _google_jwks = PyJWKClient(GOOGLE_JWKS_URL, cache_keys=True, lifespan=3600)
    return _google_jwks


async def verify_google_id_token(id_token: str) -> OAuthIdentity:
    if not settings.google_client_id:
        raise ServiceUnavailableError(
            "Google sign-in is not configured on this server",
            code="GOOGLE_NOT_CONFIGURED",
        )

    try:
        signing_key = _jwks_client().get_signing_key_from_jwt(id_token)
        claims = jwt.decode(
            id_token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.google_client_id,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
        )
    except jwt.PyJWTError as exc:
        log.info("google_id_token_rejected", reason=type(exc).__name__)
        raise AuthenticationError(
            "The Google ID token could not be verified", code="INVALID_ID_TOKEN"
        ) from exc
    except Exception as exc:
        log.warning("google_jwks_unavailable", exc_info=exc)
        raise ServiceUnavailableError(
            "Could not reach Google to verify the token"
        ) from exc

    if claims.get("iss") not in GOOGLE_ISSUERS:
        raise AuthenticationError("Unexpected token issuer", code="INVALID_ID_TOKEN")
    if not claims.get("email"):
        raise AuthenticationError(
            "The Google account has no email address", code="EMAIL_REQUIRED"
        )
    if claims.get("email_verified") is False:
        # Matching on email is only safe when the provider verified it.
        raise AuthenticationError(
            "The Google account's email address is not verified",
            code="EMAIL_NOT_VERIFIED",
        )

    return OAuthIdentity(
        provider="google",
        provider_user_id=str(claims["sub"]),
        email=str(claims["email"]),
        display_name=claims.get("name"),
    )


async def exchange_github_code(
    code: str, redirect_uri: str | None = None
) -> OAuthIdentity:
    if not (settings.github_client_id and settings.github_client_secret):
        raise ServiceUnavailableError(
            "GitHub sign-in is not configured on this server",
            code="GITHUB_NOT_CONFIGURED",
        )

    payload = {
        "client_id": settings.github_client_id,
        "client_secret": settings.github_client_secret,
        "code": code,
    }
    if redirect_uri:
        payload["redirect_uri"] = redirect_uri

    async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
        try:
            token_response = await client.post(
                GITHUB_TOKEN_URL, data=payload, headers={"Accept": "application/json"}
            )
            token_response.raise_for_status()
            token_body = token_response.json()
        except httpx.HTTPError as exc:
            log.warning("github_token_exchange_failed", exc_info=exc)
            raise ServiceUnavailableError("Could not reach GitHub") from exc

        if "error" in token_body:
            # GitHub returns 200 with an error body for a bad/expired code.
            raise BadRequestError(
                "GitHub rejected the authorization code",
                code="INVALID_OAUTH_CODE",
                details={"github_error": token_body.get("error")},
            )

        access_token = token_body.get("access_token")
        if not access_token:
            raise BadRequestError(
                "GitHub did not return an access token", code="INVALID_OAUTH_CODE"
            )

        headers = {
            "Authorization": f"Bearer {access_token}",
            "Accept": "application/vnd.github+json",
        }
        try:
            profile = (await client.get(GITHUB_USER_URL, headers=headers)).json()
            email = profile.get("email")
            if not email:
                # Users with a private email need the dedicated endpoint.
                emails = (await client.get(GITHUB_EMAILS_URL, headers=headers)).json()
                email = _primary_verified_email(emails)
        except httpx.HTTPError as exc:
            log.warning("github_profile_fetch_failed", exc_info=exc)
            raise ServiceUnavailableError("Could not read the GitHub profile") from exc

    if not email:
        raise AuthenticationError(
            "No verified email address is available on this GitHub account",
            code="EMAIL_REQUIRED",
        )

    return OAuthIdentity(
        provider="github",
        provider_user_id=str(profile["id"]),
        email=str(email),
        display_name=profile.get("name") or profile.get("login"),
    )


def _primary_verified_email(emails: object) -> str | None:
    if not isinstance(emails, list):
        return None
    verified = [e for e in emails if isinstance(e, dict) and e.get("verified")]
    for entry in verified:
        if entry.get("primary"):
            return str(entry["email"])
    return str(verified[0]["email"]) if verified else None


def _now() -> int:  # pragma: no cover - trivial indirection for tests
    return int(time.time())
