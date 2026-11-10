# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

import os
import tempfile
from pathlib import Path

import pytest

_TMP = Path(tempfile.mkdtemp(prefix="ota-test-"))
os.environ.update(
    OTA_DATABASE_URL=f"sqlite:///{_TMP / 'test.db'}",
    OTA_STORAGE_DIR=str(_TMP / "artifacts"),
    OTA_SIGNING_KEY_PATH=str(_TMP / "keys" / "signing.pem"),
    OTA_CDN_BASE_URL="http://cdn.test/cdn",
    OTA_ADMIN_API_KEY="test-admin",
    # Most tests publish straight to production; the promotion checks have their own tests.
    OTA_PROTECTED_CHANNELS="",
)

from fastapi.testclient import TestClient  # noqa: E402

from sqlalchemy import text  # noqa: E402

from app.db import get_engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Base  # noqa: E402

ADMIN = {"X-API-Key": "test-admin"}


@pytest.fixture()
def client():
    engine = get_engine()
    Base.metadata.drop_all(engine)
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE IF EXISTS alembic_version"))
    with TestClient(app) as c:  # startup runs the migrations
        yield c
