"""Periodic cleanup.

Run daily::

    docker compose exec api python -m app.jobs.maintenance

Three jobs, all safe to re-run and safe to interrupt:

* **Trash purge** — hard-delete files soft-deleted more than
  ``TRASH_RETENTION_DAYS`` ago, and remove their Telegram messages when no other
  row still references them.
* **Tombstone purge** — drop deletion records older than the window a client is
  allowed to be offline.
* **Token purge** — drop refresh tokens that can no longer be presented.

Nothing here fails the whole run because one user's channel is unreachable: a
user who revoked their bot token would otherwise block every other user's purge
forever.
"""

from __future__ import annotations

import argparse
import asyncio

from app.core.config import settings
from app.core.db import SessionFactory, dispose_engine
from app.core.logging import configure_logging, get_logger, hashed_user_id
from app.services import auth as auth_service
from app.services import files as file_service
from app.services import sync as sync_service
from app.services import telegram_config

log = get_logger(__name__)

BATCH_SIZE = 500


async def purge_trash(*, dry_run: bool = False) -> int:
    """Hard-delete expired trash. Returns the number of files purged."""
    purged = 0

    async with SessionFactory() as session:
        candidates = await file_service.list_purgeable(session, limit=BATCH_SIZE)
        if not candidates:
            return 0

        log.info(
            "trash_purge_started",
            candidates=len(candidates),
            retention_days=settings.trash_retention_days,
            dry_run=dry_run,
        )

        # One credential lookup per user, not per file.
        credentials_cache: dict[str, object] = {}

        for file in candidates:
            if dry_run:
                purged += 1
                continue

            key = str(file.user_id)
            if key not in credentials_cache:
                try:
                    credentials_cache[key] = await telegram_config.get_credentials(
                        session, file.user_id
                    )
                except Exception as exc:
                    # Unbound or unreadable channel: still drop the metadata, but
                    # leave the remote bytes alone.
                    log.warning(
                        "purge_credentials_unavailable",
                        user=hashed_user_id(file.user_id),
                        error=type(exc).__name__,
                    )
                    credentials_cache[key] = None

            try:
                await file_service.purge_file(
                    session,
                    file,
                    credentials_cache[key],  # type: ignore[arg-type]
                    delete_remote=credentials_cache[key] is not None,
                )
                purged += 1
            except Exception as exc:
                log.error("purge_failed", file_id=str(file.id), exc_info=exc)
                await session.rollback()

        await session.commit()

    log.info("trash_purge_finished", purged=purged, dry_run=dry_run)
    return purged


async def purge_tombstones() -> int:
    async with SessionFactory() as session:
        removed = await sync_service.purge_tombstones(session)
        await session.commit()
    log.info("tombstone_purge_finished", removed=removed)
    return removed


async def purge_tokens() -> int:
    async with SessionFactory() as session:
        removed = await auth_service.purge_expired_tokens(session)
        await session.commit()
    log.info("token_purge_finished", removed=removed)
    return removed


async def run_all(*, dry_run: bool = False) -> dict[str, int]:
    results = {
        "files_purged": await purge_trash(dry_run=dry_run),
        "tombstones_removed": 0 if dry_run else await purge_tombstones(),
        "tokens_removed": 0 if dry_run else await purge_tokens(),
    }
    return results


async def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Nimbus Drive maintenance tasks")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be purged without deleting anything",
    )
    parser.add_argument(
        "--task",
        choices=["all", "trash", "tombstones", "tokens"],
        default="all",
    )
    args = parser.parse_args(argv)

    configure_logging()

    try:
        if args.task == "all":
            results = await run_all(dry_run=args.dry_run)
        elif args.task == "trash":
            results = {"files_purged": await purge_trash(dry_run=args.dry_run)}
        elif args.task == "tombstones":
            results = {"tombstones_removed": await purge_tombstones()}
        else:
            results = {"tokens_removed": await purge_tokens()}

        log.info("maintenance_complete", **results)
        return 0
    except Exception as exc:
        log.error("maintenance_failed", exc_info=exc)
        return 1
    finally:
        from app.services.telegram_sessions import session_pool

        await session_pool.close_all()
        await dispose_engine()


def main() -> None:
    raise SystemExit(asyncio.run(_main()))


if __name__ == "__main__":
    main()
