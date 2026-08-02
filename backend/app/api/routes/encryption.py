"""Client-side encryption setup (spec §9.2).

Nothing here encrypts anything. These endpoints hold the salt and KDF
parameters so a user's second device can arrive at the same key, and refuse the
two operations that would silently destroy data.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Body, Query, status

from app.api.deps import CurrentUser, SessionDep
from app.core.envelope import Envelope, ok
from app.schemas.encryption import (
    MINIMUMS,
    RECOMMENDED,
    EncryptionOut,
    EncryptionRecommendationOut,
    EncryptionSetupIn,
    Kdf,
)
from app.services import encryption as service

router = APIRouter(prefix="/encryption", tags=["encryption"])


async def _out(session: SessionDep, user: CurrentUser) -> EncryptionOut:
    data = await service.describe(session, user)
    return EncryptionOut(**data, enabled_at=service.enabled_at(user))


@router.get(
    "/recommended",
    response_model=Envelope[EncryptionRecommendationOut],
    summary="Recommended KDF parameters",
)
async def recommended(
    kdf: Annotated[Kdf, Query(description="Algorithm to describe")] = Kdf.ARGON2ID,
) -> Envelope[EncryptionRecommendationOut]:
    """Parameters a client should use, so none of this is hard-coded in the app.

    Unauthenticated on purpose: it is public cryptographic guidance, not
    account data, and the setup screen may want it before sign-in completes.
    """
    return ok(
        EncryptionRecommendationOut(
            kdf=kdf, kdf_params=RECOMMENDED[kdf], minimums=MINIMUMS[kdf]
        )
    )


@router.get(
    "",
    response_model=Envelope[EncryptionOut],
    summary="Current encryption parameters",
)
async def get_encryption(
    session: SessionDep, user: CurrentUser
) -> Envelope[EncryptionOut]:
    """Salt, KDF and verifier for this account.

    This is what a freshly installed app calls to re-derive the key from a
    password the user already knows. Returns `enabled: false` and nulls when
    encryption was never set up — not a 404, because "no encryption" is a
    perfectly normal state to report.
    """
    return ok(await _out(session, user))


@router.post(
    "",
    response_model=Envelope[EncryptionOut],
    status_code=status.HTTP_201_CREATED,
    summary="Enable client-side encryption",
)
async def enable_encryption(
    payload: EncryptionSetupIn, session: SessionDep, user: CurrentUser
) -> Envelope[EncryptionOut]:
    """Generate and store a salt, and record how the key is derived from it.

    The password is never sent here — only the client ever sees it. Enabling
    twice is rejected: a second salt would orphan every file sealed under the
    first, and there is no recovery path.
    """
    assert payload.kdf_params is not None  # set by the model validator
    await service.enable(
        session,
        user,
        kdf=payload.kdf,
        kdf_params=payload.kdf_params,
        verifier=payload.verifier,
    )
    return ok(await _out(session, user))


@router.put(
    "/verifier",
    response_model=Envelope[EncryptionOut],
    summary="Set the password-check blob",
)
async def put_verifier(
    session: SessionDep,
    user: CurrentUser,
    verifier: Annotated[str, Body(embed=True, description="Base64 AES-GCM blob")],
) -> Envelope[EncryptionOut]:
    """Attach a verifier after the fact.

    For clients that enabled encryption before they produced one. Without it a
    wrong password is only detected when the first download fails to
    authenticate.
    """
    await service.set_verifier(session, user, verifier)
    return ok(await _out(session, user))


@router.delete(
    "",
    response_model=Envelope[EncryptionOut],
    summary="Disable client-side encryption",
)
async def disable_encryption(
    session: SessionDep,
    user: CurrentUser,
    force: Annotated[
        bool,
        Query(
            description=(
                "Accept that existing encrypted files become permanently "
                "unreadable. Required while any still exist."
            )
        ),
    ] = False,
) -> Envelope[EncryptionOut]:
    """Forget the salt and KDF parameters.

    Refused by default while encrypted files remain — including in the trash —
    because discarding the salt makes them unreadable forever. No file is
    deleted either way.
    """
    await service.disable(session, user, force=force)
    return ok(await _out(session, user))
