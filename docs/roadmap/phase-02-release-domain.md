# Phase 2 — Release domain (2–3 pw)

> **Roadmap status: ✅ implemented in a simpler form.** The code has 9 tables in
> `backend/app/models.py`: `applications`, `channels`, `releases`, `release_artifacts`, `patches`,
> `patch_artifacts`, `patch_deployments`, `devices`, `patch_event_counts`. Patch states are
> `draft → published → rolled_back / revoked`, with per-release patch numbers and a release
> fingerprint check for code patches.
> 🔭 Planned, not built: `signing_keys`, `device_credentials`, `device_patch_state`,
> `deployment_events`, `audit_events`, `idempotency_keys`, and Postgres tests with
> testcontainers (the tests use SQLite).

**Goal:** database tables for applications, channels, releases, artifacts and patches, plus the business rules that connect them. Everything later (update checks, rollouts) reads these tables.

**New concepts:** SQLAlchemy models, Alembic migrations, repositories/services, a state machine, testing against a real Postgres.

Before you start: Phase 1 done, Docker running (`make up`), and a new branch: `git switch -c phase-2-release-domain`.

---

## 2.1 Configure model defaults

**Why:** you want every timestamp to be timezone-aware and every string to be Postgres `text`, without repeating it on every column.

**Do:** replace `backend/app/models/__init__.py` with:

```python
"""SQLAlchemy models. Every model module must be imported at the bottom of this file."""

from datetime import datetime

from sqlalchemy import DateTime, Text
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    type_annotation_map = {
        datetime: DateTime(timezone=True),
        str: Text,
    }


# Import models so Alembic's autogenerate can see them.
from app.models.application import Application, Channel  # noqa: E402, F401
```

---

## 2.2 Write the first models: applications and channels

**Why:** start with two small tables to learn the pattern, then repeat it.

**Do:** create `backend/app/models/application.py`:

```python
import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, ForeignKey, UniqueConstraint, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.models import Base


class Application(Base):
    __tablename__ = "applications"
    __table_args__ = (
        CheckConstraint("status IN ('active', 'disabled')", name="ck_applications_status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        primary_key=True, server_default=text("gen_random_uuid()")
    )
    slug: Mapped[str] = mapped_column(unique=True)
    name: Mapped[str]
    android_package_id: Mapped[str | None]
    ios_bundle_id: Mapped[str | None]
    status: Mapped[str] = mapped_column(server_default="active")
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    created_by: Mapped[str]


class Channel(Base):
    __tablename__ = "channels"
    __table_args__ = (UniqueConstraint("application_id", "name"),)

    id: Mapped[uuid.UUID] = mapped_column(
        primary_key=True, server_default=text("gen_random_uuid()")
    )
    application_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("applications.id"))
    name: Mapped[str]
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
```

How to read this:
- `Mapped[str]` means NOT NULL. `Mapped[str | None]` means nullable.
- `server_default=` means the **database** fills the value, so it also works for rows inserted outside Python.
- `gen_random_uuid()` is built into Postgres 13+.

> **Scope note (ADR-0011):** also add two columns to `Application`: `distribution: Mapped[str] = mapped_column(server_default="enterprise")` (allowed values `public_store` / `enterprise`, add a `CheckConstraint`) and `aot_policy_approved: Mapped[bool] = mapped_column(server_default=text("false"))`. In 2.9 (compatibility service) and in publishing, reject an `aot-bidiff-android-v1` patch for a `public_store` app unless `aot_policy_approved` is true.

**Check:** `cd backend && .venv/bin/python -c "from app.models import Base; print(Base.metadata.tables.keys())"` prints both tables.

---

## 2.3 Generate and apply the first migration

**Why:** a migration is a versioned script that creates or changes tables. Alembic compares your models to the real database and writes the script for you.

**Do:**

```bash
make migration m="applications and channels"
```

Open the new file in `backend/migrations/versions/`. **Always read generated migrations.** Autogenerate can miss things (it does not detect renamed columns, for example). Then:

```bash
make migrate
docker compose exec postgres psql -U ota -d ota -c '\d applications'
```

**Check:** `\d applications` shows the columns and the check constraint. Try `make migrate` again: nothing happens, because it is already at head.

To undo the last migration: `cd backend && .venv/bin/alembic downgrade -1`.

---

## 2.4 Model the remaining tables

**Why:** this is the full **planned** schema. Convert each table into a model the same way as 2.2. (The current code uses a smaller schema: see the status box at the top.)

**Do:** create one module per area and import each in `app/models/__init__.py`:

| Module | Tables (planned) | Watch out for |
|---|---|---|
| `release.py` | `releases`, `release_artifacts` | `base_manifest_sha256` / `sha256` are `CHAR(64)`: use `mapped_column(CHAR(64))` from `sqlalchemy` |
| `patch.py` | `patches`, `patch_artifacts` | `patch_number > 0` check. `UNIQUE (release_id, patch_number)`. Index `(release_id, status, patch_number DESC)` via `Index("idx_...", "release_id", "status", text("patch_number DESC"))` |
| `signing.py` | `signing_keys` | FK from `patch_artifacts.signing_key_id` |
| `device.py` | `devices`, `device_credentials`, `device_patch_state` | `refresh_hash` is `LargeBinary` (bytea). `ON DELETE CASCADE` via `ForeignKey(..., ondelete="CASCADE")` |
| `rollout.py` | `rollouts`, `deployment_events` | `targeting` is `JSONB` (`from sqlalchemy.dialects.postgresql import JSONB`). Partial unique index: `Index("ux_rollout_active_patch_channel", "patch_id", "channel_id", unique=True, postgresql_where=text("state IN ('running','paused')"))` |
| `audit.py` | `audit_events`, `idempotency_keys` | See below |

Two more planned tables, defined here:

```
deployment_events: id, application_id, channel_id, patch_id (nullable),
                   event_type ('publish','promote','pause','resume','percentage_changed','rollback','revoke'),
                   actor_id, before (jsonb), after (jsonb), created_at
                   -- append-only: never UPDATE or DELETE rows here

idempotency_keys:  key (text), actor_id (text), request_hash (char 64),
                   response_status (int), response_body (jsonb), created_at, expires_at
                   PRIMARY KEY (actor_id, key)
```

Also add `revoked_patch_ids` support: nothing new is needed, because `patches.status = 'revoked'` is enough.

Then: `make migration m="release domain"` → read it → `make migrate`.

**Check:** `\dt` in psql lists all tables. `make migration m="noop"` generates an **empty** migration, which proves models and database match. Delete that empty file.

---

## 2.5 Set up database tests with testcontainers

**Why:** tests against a fake database hide real bugs (constraints, SQL). testcontainers starts a throwaway Postgres in Docker for the test run.

**Do:**
1. Add `"testcontainers[postgres]>=4"` to `dev` in `backend/pyproject.toml`, then `make backend-install`.
2. Create `backend/tests/integration/__init__.py` (empty) and `backend/tests/integration/conftest.py`:

```python
import os

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy.ext.asyncio import create_async_engine
from testcontainers.postgres import PostgresContainer

from app.config import get_settings
from app.db import create_session_factory


@pytest.fixture(scope="session")
def database_url():
    with PostgresContainer("postgres:16", driver="asyncpg") as pg:
        url = pg.get_connection_url()
        os.environ["OTA_DATABASE_URL"] = url
        get_settings.cache_clear()  # settings are cached. Force a re-read
        command.upgrade(Config("alembic.ini"), "head")
        yield url


@pytest.fixture
async def session(database_url):
    engine = create_async_engine(database_url)
    async with engine.connect() as conn:
        trans = await conn.begin()
        factory = create_session_factory(engine)
        async with factory(bind=conn) as s:
            yield s
        await trans.rollback()  # every test starts from an empty database
    await engine.dispose()
```

3. Write a first test, `tests/integration/test_models.py`:

```python
import pytest
from sqlalchemy.exc import IntegrityError

from app.models import Application


async def test_application_slug_is_unique(session):
    session.add(Application(slug="shop", name="Shop", created_by="test"))
    await session.flush()
    session.add(Application(slug="shop", name="Shop 2", created_by="test"))
    with pytest.raises(IntegrityError):
        await session.flush()
```

**Check:** `make backend-test` passes. The first run downloads the Postgres image, so it is slow.

---

## 2.6 Repositories and services

**Why:** keep SQL out of the HTTP layer.
- A **repository** only talks to the database (`get_release(id)`, `add_patch(...)`).
- A **service** holds business rules ("a patch number must be the next one").
- The **API route** only converts HTTP ↔ service calls.

**Do:** create `app/repositories/` and `app/services/` with one module per area. Example `app/repositories/applications.py`:

```python
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Application


class ApplicationRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def get(self, application_id: uuid.UUID) -> Application | None:
        return await self.session.get(Application, application_id)

    async def get_by_slug(self, slug: str) -> Application | None:
        result = await self.session.execute(select(Application).where(Application.slug == slug))
        return result.scalar_one_or_none()

    async def add(self, app: Application) -> Application:
        self.session.add(app)
        await self.session.flush()  # sends INSERT, fills app.id
        return app
```

**Check:** an integration test that adds and then reads back an application.

---

## 2.7 Patch state machine

**Why:** a patch moves `draft → validated → published → superseded | revoked`. Illegal moves (for example publishing a draft that was never validated) must be impossible.

**Do:** `app/services/patch_state.py`:

```python
ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "draft": {"validated"},
    "validated": {"published", "draft"},
    "published": {"superseded", "revoked"},
    "superseded": {"revoked"},
    "revoked": set(),  # terminal: a revoked patch can never come back
}


class InvalidTransition(Exception):
    def __init__(self, current: str, target: str):
        super().__init__(f"cannot move patch from {current!r} to {target!r}")


def ensure_transition(current: str, target: str) -> None:
    if target not in ALLOWED_TRANSITIONS[current]:
        raise InvalidTransition(current, target)
```

**Check:** unit tests in `tests/unit/test_patch_state.py` for **every** allowed and at least 5 forbidden transitions. Use `pytest.mark.parametrize` to keep it short.

---

## 2.8 Patch numbering

**Why:** patch numbers must be 1, 2, 3… per release with no duplicates, even if two CI jobs create patches at the same moment.

**Do:** in the patch service:

```python
async def next_patch_number(session, release_id) -> int:
    # Lock the release row so two concurrent creators wait for each other.
    await session.execute(select(Release.id).where(Release.id == release_id).with_for_update())
    result = await session.execute(
        select(func.coalesce(func.max(Patch.patch_number), 0)).where(Patch.release_id == release_id)
    )
    return result.scalar_one() + 1
```

The `UNIQUE (release_id, patch_number)` constraint is your safety net if this ever goes wrong.

**Check:** integration test that creates 3 patches and gets numbers 1, 2, 3.

---

## 2.9 Compatibility service

**Why:** the most important safety rule. A patch built for app 1.0.0 / engine A / arm64 must **never** be sent to app 1.1.0 / engine B. This is a pure function (no database), so it is easy to test completely.

**Do:** `app/services/compatibility.py`:

```python
from dataclasses import dataclass
from enum import StrEnum


class Incompatibility(StrEnum):
    INCOMPATIBLE_RELEASE = "INCOMPATIBLE_RELEASE"
    INCOMPATIBLE_RUNTIME = "INCOMPATIBLE_RUNTIME"


@dataclass(frozen=True)
class DeviceInfo:
    application_id: str
    release_id: str
    platform: str
    arch: str
    runtime_abi: str
    supported_formats: frozenset[str]


@dataclass(frozen=True)
class PatchTarget:
    application_id: str
    release_id: str
    platform: str
    arch: str
    runtime_abi: str
    artifact_format: str


def check_compatibility(device: DeviceInfo, patch: PatchTarget) -> Incompatibility | None:
    """Return None if compatible, otherwise the reason. Order matters: most basic first."""
    if (device.application_id, device.release_id, device.platform, device.arch) != (
        patch.application_id, patch.release_id, patch.platform, patch.arch
    ):
        return Incompatibility.INCOMPATIBLE_RELEASE
    if device.runtime_abi != patch.runtime_abi:
        return Incompatibility.INCOMPATIBLE_RUNTIME
    if patch.artifact_format not in device.supported_formats:
        return Incompatibility.INCOMPATIBLE_RUNTIME
    return None
```

Flutter, Dart and engine versions do not need separate checks here: they are properties of the **release**, and the release ID must already match exactly. The base artifact hash is checked on the device in Phase 5.

**Check:** one unit test per field that can mismatch, plus the happy path.

---

## 2.10 Temporary admin endpoints

**Why:** you need a way to create test data before real login exists (Phase 8).

**Do:**
1. Add `admin_dev_api_key: str | None = None` to `Settings`.
2. Create a dependency that requires the header `X-Admin-Key` to equal it. If the setting is empty, reject everything, so the key can never be accidentally open in Azure.
3. Add Pydantic schemas in `app/schemas/` and routes in `app/api/admin.py`:

| Method | Path | Body |
|---|---|---|
| POST | `/v1/admin/applications` | slug, name, package IDs |
| POST | `/v1/admin/applications/{id}/channels` | name |
| POST | `/v1/admin/releases` | application_id, platform, version, build_number, flutter/dart/engine versions, runtime_version, runtime_abi, git_commit_sha, base_manifest_sha256 |
| POST | `/v1/admin/releases/{id}/artifacts` | arch, artifact_type, blob_key, sha256, size_bytes, content_type |
| POST | `/v1/admin/patches` | release_id, source_git_sha, mandatory, release_notes |
| POST | `/v1/admin/patches/{id}/validate` | none (uses the state machine) |
| POST | `/v1/admin/patches/{id}/publish` | none |

4. Every mutation also inserts an `audit_events` row **in the same transaction**, with `request_id` taken from `request.state.request_id`.

**Check:** in http://localhost:8000/docs, click *Authorize* (or add the header), then create an app → channel → release → patch → validate → publish. Look at `audit_events` in psql: 6 rows.

---

## Phase 2 is done when

- [ ] All planned tables exist, and an autogenerated "noop" migration is empty
- [ ] Integration tests run against a real Postgres in Docker
- [ ] State machine and compatibility have full unit tests
- [ ] You can create a published patch through the API, and every step is audited
- [ ] PR merged with green CI

> CI note: GitHub's `ubuntu-latest` runners have Docker, so testcontainers works in CI without changes.
