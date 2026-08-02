"""Alembic environment.

Runs migrations through the application's own async engine so there is exactly
one connection string in the project (``DATABASE_URL``) and no chance of
migrating a different database than the app talks to.
"""

from __future__ import annotations

import asyncio
from logging.config import fileConfig

from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from alembic import context
from app.core.config import settings
from app.models import Base

config = context.config

# `%` is configparser's interpolation character, and alembic.ini is a
# configparser file — so a URL containing one (any percent-encoded password,
# e.g. `%24` for `$`) raises "invalid interpolation syntax" before a single
# migration runs. Doubling escapes it back to a literal `%`.
config.set_main_option("sqlalchemy.url", settings.database_url.replace("%", "%%"))

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def _include_object(object_, name, type_, reflected, compare_to) -> bool:  # type: ignore[no-untyped-def]
    """Keep autogenerate away from things it did not create.

    The pg_trgm index is raw DDL (Alembic cannot express `gin_trgm_ops`), so
    without this every autogenerate would helpfully propose dropping it.
    """
    return not (type_ == "index" and name == "ix_files_name_trgm")


def run_migrations_offline() -> None:
    context.configure(
        url=settings.database_url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
        compare_server_default=True,
        include_object=_include_object,
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,
        compare_server_default=True,
        include_object=_include_object,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
