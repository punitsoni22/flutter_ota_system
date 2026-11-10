# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Alembic environment. The database URL comes from the app settings (OTA_DATABASE_URL)."""

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.config import get_settings
from app.models import Base

config = context.config
target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(url=get_settings().database_url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    # The app passes its own connection (see app/migrate.py) so the startup lock covers migrations.
    connection = config.attributes.get("connection")
    if connection is not None:
        context.configure(connection=connection, target_metadata=target_metadata, render_as_batch=True)
        with context.begin_transaction():
            context.run_migrations()
        return
    engine = engine_from_config(
        {"sqlalchemy.url": get_settings().database_url}, prefix="sqlalchemy.", poolclass=pool.NullPool
    )
    with engine.connect() as conn:
        context.configure(connection=conn, target_metadata=target_metadata, render_as_batch=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
