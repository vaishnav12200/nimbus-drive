"""Client-side encryption setup.

The backend holds no key and performs no crypto here, so most of these tests
are about guardrails: the operations that would silently make a user's files
permanently unreadable must be refused, not merely discouraged.
"""

from __future__ import annotations

import base64
import os
from typing import Any

import pytest
from httpx import AsyncClient

from tests.conftest import auth_headers, file_payload, register_user

RECOMMENDED_ARGON2 = {"memory_kib": 65536, "iterations": 3, "parallelism": 1}


def fake_verifier(size: int = 60) -> str:
    """A blob shaped like IV(12) + ciphertext + GCM tag(16). Its contents are
    opaque to the server, so random bytes are a faithful stand-in."""
    return base64.b64encode(os.urandom(size)).decode()


async def enable(client: AsyncClient, headers: dict[str, str], **kwargs: Any) -> Any:
    payload = {"kdf": "argon2id", "kdf_params": RECOMMENDED_ARGON2, **kwargs}
    return await client.post("/api/encryption", json=payload, headers=headers)


async def new_user(client: AsyncClient) -> tuple[dict[str, Any], dict[str, str]]:
    tokens = await register_user(client)
    return tokens, auth_headers(tokens)


class TestRecommendations:
    async def test_defaults_meet_their_own_minimums(self, client: AsyncClient) -> None:
        """Parameters we advertise must pass the validator that enforces them —
        otherwise a client following our own advice gets rejected."""
        body = (await client.get("/api/encryption/recommended")).json()["data"]
        for name, floor in body["minimums"].items():
            assert body["kdf_params"][name] >= floor

    async def test_iv_is_twelve_bytes(self, client: AsyncClient) -> None:
        """The spec said 16; AES-GCM's standard is 12. Clients read this rather
        than hard-coding it, so it is worth pinning."""
        body = (await client.get("/api/encryption/recommended")).json()["data"]
        assert body["iv_bytes"] == 12
        assert body["cipher"] == "AES-256-GCM"
        assert body["salt_bytes"] == 32

    async def test_pbkdf2_recommendation_is_current(self, client: AsyncClient) -> None:
        body = (await client.get("/api/encryption/recommended?kdf=pbkdf2-sha256")).json()[
            "data"
        ]
        # The spec's 100_000 is roughly a sixth of current OWASP guidance.
        assert body["kdf_params"]["iterations"] >= 600_000


class TestEnabling:
    async def test_disabled_by_default(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        body = (await client.get("/api/encryption", headers=headers)).json()["data"]
        assert body["enabled"] is False
        assert body["salt"] is None

    async def test_enabling_returns_a_32_byte_salt(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        response = await enable(client, headers)
        assert response.status_code == 201, response.text

        body = response.json()["data"]
        assert body["enabled"] is True
        assert len(base64.b64decode(body["salt"])) == 32
        assert body["kdf"] == "argon2id"
        assert body["kdf_params"] == RECOMMENDED_ARGON2

    async def test_salt_is_unique_per_account(self, client: AsyncClient) -> None:
        salts = set()
        for _ in range(3):
            _, headers = await new_user(client)
            salts.add((await enable(client, headers)).json()["data"]["salt"])
        assert len(salts) == 3

    async def test_params_default_when_omitted(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        response = await client.post(
            "/api/encryption", json={"kdf": "argon2id"}, headers=headers
        )
        assert response.json()["data"]["kdf_params"] == RECOMMENDED_ARGON2

    async def test_salt_survives_a_new_device(self, client: AsyncClient) -> None:
        """The entire point: a reinstalled app must re-derive the same key."""
        tokens, headers = await new_user(client)
        first = (await enable(client, headers)).json()["data"]

        fresh = await client.post(
            "/api/auth/login",
            json={"email": tokens["email"], "password": tokens["password"]},
        )
        second = (
            await client.get(
                "/api/encryption", headers=auth_headers(fresh.json()["data"])
            )
        ).json()["data"]

        assert second["salt"] == first["salt"]
        assert second["kdf"] == first["kdf"]
        assert second["kdf_params"] == first["kdf_params"]

    async def test_enabling_twice_is_refused(self, client: AsyncClient) -> None:
        """A second salt would orphan every file sealed under the first."""
        _, headers = await new_user(client)
        await enable(client, headers)

        response = await enable(client, headers)
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "ENCRYPTION_ALREADY_ENABLED"

    async def test_original_salt_untouched_after_a_refused_retry(
        self, client: AsyncClient
    ) -> None:
        _, headers = await new_user(client)
        before = (await enable(client, headers)).json()["data"]
        await enable(client, headers)
        after = (await client.get("/api/encryption", headers=headers)).json()["data"]
        assert after["salt"] == before["salt"]


class TestWeakParameters:
    """A client may choose its KDF, but not one so weak the user cannot tell."""

    @pytest.mark.parametrize(
        ("kdf", "params"),
        [
            ("pbkdf2-sha256", {"iterations": 100_000}),  # the spec's own figure
            ("pbkdf2-sha256", {"iterations": 1}),
            ("argon2id", {"memory_kib": 512, "iterations": 3, "parallelism": 1}),
            ("argon2id", {"memory_kib": 65536, "iterations": 1, "parallelism": 1}),
        ],
    )
    async def test_below_minimum_is_rejected(
        self, client: AsyncClient, kdf: str, params: dict[str, int]
    ) -> None:
        _, headers = await new_user(client)
        response = await client.post(
            "/api/encryption",
            json={"kdf": kdf, "kdf_params": params},
            headers=headers,
        )
        assert response.status_code == 422

    async def test_missing_required_param_is_rejected(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        response = await client.post(
            "/api/encryption",
            json={"kdf": "argon2id", "kdf_params": {"iterations": 3}},
            headers=headers,
        )
        assert response.status_code == 422

    async def test_a_stronger_choice_is_allowed(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        response = await client.post(
            "/api/encryption",
            json={
                "kdf": "argon2id",
                "kdf_params": {"memory_kib": 131072, "iterations": 4, "parallelism": 2},
            },
            headers=headers,
        )
        assert response.status_code == 201


class TestVerifier:
    async def test_round_trips_unchanged(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        blob = fake_verifier()
        body = (await enable(client, headers, verifier=blob)).json()["data"]
        assert body["verifier"] == blob

    async def test_can_be_added_later(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        await enable(client, headers)
        blob = fake_verifier()

        response = await client.put(
            "/api/encryption/verifier", json={"verifier": blob}, headers=headers
        )
        assert response.status_code == 200
        assert response.json()["data"]["verifier"] == blob

    async def test_requires_encryption_enabled(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        response = await client.put(
            "/api/encryption/verifier",
            json={"verifier": fake_verifier()},
            headers=headers,
        )
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "ENCRYPTION_NOT_ENABLED"

    @pytest.mark.parametrize(
        "bad", ["not base64!!", "", base64.b64encode(b"tiny").decode()]
    )
    async def test_malformed_is_rejected(self, client: AsyncClient, bad: str) -> None:
        _, headers = await new_user(client)
        assert (await enable(client, headers, verifier=bad)).status_code == 422


class TestDisabling:
    async def test_clears_every_parameter(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        await enable(client, headers, verifier=fake_verifier())

        body = (await client.delete("/api/encryption", headers=headers)).json()["data"]
        assert body["enabled"] is False
        assert body["salt"] is None
        assert body["kdf"] is None
        assert body["verifier"] is None

    async def test_when_not_enabled_is_rejected(self, client: AsyncClient) -> None:
        _, headers = await new_user(client)
        response = await client.delete("/api/encryption", headers=headers)
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "ENCRYPTION_NOT_ENABLED"


class TestUploadGuard:
    async def test_encrypted_upload_refused_without_setup(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        """Otherwise the row records a file whose key nothing can describe."""
        response = await client.post(
            "/api/files",
            json=file_payload(is_encrypted=True),
            headers=bound_user["headers"],
        )
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "ENCRYPTION_NOT_ENABLED"

    async def test_encrypted_upload_allowed_after_setup(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        headers = bound_user["headers"]
        await enable(client, headers)
        response = await client.post(
            "/api/files", json=file_payload(is_encrypted=True), headers=headers
        )
        assert response.status_code == 201
        assert response.json()["data"]["is_encrypted"] is True

    async def test_unencrypted_upload_unaffected(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        response = await client.post(
            "/api/files", json=file_payload(), headers=bound_user["headers"]
        )
        assert response.status_code == 201

    async def test_reserve_is_guarded_too(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        """The large-file path must not be a way around the check."""
        response = await client.post(
            "/api/files/reserve",
            json={"name": "big.bin", "size": 50_000_000, "is_encrypted": True},
            headers=bound_user["headers"],
        )
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "ENCRYPTION_NOT_ENABLED"


class TestDisableWithEncryptedFiles:
    async def test_refused_while_encrypted_files_exist(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        """Discarding the salt would make them unreadable forever."""
        headers = bound_user["headers"]
        await enable(client, headers)
        await client.post(
            "/api/files", json=file_payload(is_encrypted=True), headers=headers
        )

        response = await client.delete("/api/encryption", headers=headers)
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "ENCRYPTION_IN_USE"
        assert response.json()["error"]["details"]["encrypted_file_count"] == 1

    async def test_trashed_files_still_count(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        """A trashed file is restorable, so it is still data worth protecting."""
        headers = bound_user["headers"]
        await enable(client, headers)
        created = await client.post(
            "/api/files", json=file_payload(is_encrypted=True), headers=headers
        )
        await client.delete(f"/api/files/{created.json()['data']['id']}", headers=headers)

        response = await client.delete("/api/encryption", headers=headers)
        assert response.status_code == 409

    async def test_force_overrides(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        headers = bound_user["headers"]
        await enable(client, headers)
        await client.post(
            "/api/files", json=file_payload(is_encrypted=True), headers=headers
        )

        response = await client.delete("/api/encryption?force=true", headers=headers)
        assert response.status_code == 200
        assert response.json()["data"]["enabled"] is False

    async def test_unencrypted_files_do_not_block(
        self, client: AsyncClient, bound_user: dict[str, Any]
    ) -> None:
        headers = bound_user["headers"]
        await enable(client, headers)
        await client.post("/api/files", json=file_payload(), headers=headers)

        assert (
            await client.delete("/api/encryption", headers=headers)
        ).status_code == 200


class TestIsolation:
    async def test_one_account_cannot_see_another_salt(self, client: AsyncClient) -> None:
        _, headers_a = await new_user(client)
        _, headers_b = await new_user(client)
        salt_a = (await enable(client, headers_a)).json()["data"]["salt"]

        body_b = (await client.get("/api/encryption", headers=headers_b)).json()["data"]
        assert body_b["enabled"] is False
        assert body_b["salt"] != salt_a

    @pytest.mark.parametrize(
        ("method", "path"),
        [
            ("get", "/api/encryption"),
            ("post", "/api/encryption"),
            ("delete", "/api/encryption"),
            ("put", "/api/encryption/verifier"),
        ],
    )
    async def test_endpoints_require_auth(
        self, client: AsyncClient, method: str, path: str
    ) -> None:
        response = await getattr(client, method)(path)
        assert response.status_code == 401
