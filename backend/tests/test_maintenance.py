"""The daily maintenance job."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import select

from app.jobs import maintenance
from app.models import File, RefreshToken, SyncTombstone
from tests.conftest import file_payload


async def _trash_a_file(
    client: AsyncClient, headers: dict[str, str], session: Any, *, age_days: int
) -> str:
    created = (
        await client.post("/api/files", headers=headers, json=file_payload())
    ).json()["data"]
    await client.delete(f"/api/files/{created['id']}", headers=headers)

    row = (
        await session.execute(select(File).where(File.id == created["id"]))
    ).scalar_one()
    row.deleted_at = datetime.now(UTC) - timedelta(days=age_days)
    await session.commit()
    return str(created["id"])


async def test_expired_trash_is_purged(
    client: AsyncClient, bound_user: dict[str, Any], session: Any
) -> None:
    file_id = await _trash_a_file(client, bound_user["headers"], session, age_days=45)

    purged = await maintenance.purge_trash()
    assert purged == 1

    assert (
        await client.get(f"/api/files/{file_id}", headers=bound_user["headers"])
    ).status_code == 404


async def test_recent_trash_is_left_alone(
    client: AsyncClient, bound_user: dict[str, Any], session: Any
) -> None:
    """The 30-day window is the user's safety net; the job must respect it."""
    file_id = await _trash_a_file(client, bound_user["headers"], session, age_days=3)

    assert await maintenance.purge_trash() == 0

    still_there = await client.get(f"/api/files/{file_id}", headers=bound_user["headers"])
    assert still_there.status_code == 200
    assert still_there.json()["data"]["is_deleted"] is True


async def test_dry_run_deletes_nothing(
    client: AsyncClient, bound_user: dict[str, Any], session: Any
) -> None:
    file_id = await _trash_a_file(client, bound_user["headers"], session, age_days=45)

    assert await maintenance.purge_trash(dry_run=True) == 1

    assert (
        await client.get(f"/api/files/{file_id}", headers=bound_user["headers"])
    ).status_code == 200


async def test_purging_leaves_a_tombstone_for_offline_clients(
    client: AsyncClient, bound_user: dict[str, Any], session: Any
) -> None:
    file_id = await _trash_a_file(client, bound_user["headers"], session, age_days=45)
    await maintenance.purge_trash()

    tombstones = (await session.execute(select(SyncTombstone.entity_id))).scalars().all()
    assert str(tombstones[0]) == file_id


async def test_old_tombstones_are_swept(session: Any, bound_user: dict[str, Any]) -> None:
    import uuid

    from sqlalchemy import select as sa_select

    from app.models import User

    user = (
        await session.execute(
            sa_select(User).where(User.email == bound_user["email"].lower())
        )
    ).scalar_one()

    session.add(
        SyncTombstone(
            user_id=user.id,
            entity_type="folder",
            entity_id=uuid.uuid4(),
            deleted_at=datetime.now(UTC) - timedelta(days=200),
        )
    )
    session.add(
        SyncTombstone(user_id=user.id, entity_type="folder", entity_id=uuid.uuid4())
    )
    await session.commit()

    assert await maintenance.purge_tombstones() == 1

    remaining = (await session.execute(select(SyncTombstone))).scalars().all()
    assert len(remaining) == 1


async def test_dead_refresh_tokens_are_swept(
    session: Any, bound_user: dict[str, Any]
) -> None:
    rows = (await session.execute(select(RefreshToken))).scalars().all()
    assert len(rows) == 1

    # Well past the point where it could still be presented.
    rows[0].expires_at = datetime.now(UTC) - timedelta(days=60)
    await session.commit()

    assert await maintenance.purge_tokens() == 1


async def test_run_all_reports_each_task(
    client: AsyncClient, bound_user: dict[str, Any], session: Any
) -> None:
    await _trash_a_file(client, bound_user["headers"], session, age_days=45)

    results = await maintenance.run_all()
    assert results["files_purged"] == 1
    assert set(results) == {"files_purged", "tombstones_removed", "tokens_removed"}
