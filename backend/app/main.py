# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text

from app import migrate
from app.config import get_settings
from app.db import get_engine
from app.deps import get_signer, get_storage
from app.routers import admin, devices, trust

log = logging.getLogger("ota")

_STARTUP_LOCK_ID = 727001


@asynccontextmanager
async def lifespan(_: FastAPI):
    # Uvicorn runs several workers. The lock stops them racing to migrate the schema and to create
    # the dev signing key (without it, two workers can each write a different key).
    settings = get_settings()
    if settings.env == "production" and (problems := settings.production_problems()):
        raise RuntimeError("Unsafe production settings:\n  " + "\n  ".join(problems))
    engine = get_engine()
    with engine.begin() as conn:
        if engine.dialect.name == "postgresql":
            conn.execute(text("SELECT pg_advisory_xact_lock(:id)"), {"id": _STARTUP_LOCK_ID})
        migrate.upgrade(conn)
        signer = get_signer()
    log.info("Signing key id=%s", signer.key_id)
    yield


def create_app() -> FastAPI:
    settings = get_settings()
    # API docs only off the server: in production they would map the admin API for anyone.
    docs = {} if settings.env != "production" else {"docs_url": None, "redoc_url": None, "openapi_url": None}
    app = FastAPI(title="Flutter OTA System", version="0.1.0-alpha.1", lifespan=lifespan, **docs)
    app.include_router(devices.router)
    app.include_router(admin.router)
    app.include_router(trust.router)

    @app.get("/health/live", tags=["health"])
    def live():
        return {"status": "ok"}

    @app.get("/health/ready", tags=["health"])
    def ready():
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        return {"status": "ok"}

    @app.get("/admin", include_in_schema=False)
    def admin_page():
        # Static page. It calls the admin API with the key you type in, so it holds no secrets.
        return FileResponse(Path(__file__).parent / "admin.html")

    if settings.serve_artifacts_locally and settings.storage_backend == "local":
        # Local runs only. With Docker Compose, nginx (the "CDN") serves these files instead.
        # Only patches: release base files are the app's whole code and stay private.
        patches = get_storage().root / "patches"
        patches.mkdir(parents=True, exist_ok=True)
        app.mount("/cdn/patches", StaticFiles(directory=patches), name="cdn")
    return app


app = create_app()
