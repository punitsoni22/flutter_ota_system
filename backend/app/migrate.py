# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Brings the database schema up to date with Alembic (backend/migrations)."""

from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import inspect
from sqlalchemy.engine import Connection

BACKEND_DIR = Path(__file__).resolve().parents[1]


def upgrade(conn: Connection) -> None:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    cfg.attributes["connection"] = conn
    tables = set(inspect(conn).get_table_names())
    if "applications" in tables and "alembic_version" not in tables:
        # Created by the MVP's create_all before migrations existed: that schema is revision 0001.
        command.stamp(cfg, "0001")
    command.upgrade(cfg, "head")
