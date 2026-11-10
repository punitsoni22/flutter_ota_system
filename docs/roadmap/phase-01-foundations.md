# Phase 1 — Foundations (2–3 pw)

> **Roadmap status: ✅ mostly implemented.** Built: settings from `OTA_*` environment variables,
> health endpoints, Alembic migrations, `backend/Dockerfile`, `docker-compose.yml`, backend tests,
> GitHub Actions CI ([ci.yml](../../.github/workflows/ci.yml)).
> Not built: request IDs (1.4), a custom error format (1.5), the Makefile (1.13) and the Flutter
> pub workspace (1.14). The real file layout differs from this guide: see `backend/app/`.
> Step 1.16 (protect `main`) is a manual GitHub setting
> ([MANUAL_SECURITY_CHECKLIST.md](../release/MANUAL_SECURITY_CHECKLIST.md) §C).

**Goal:** a project skeleton where the API runs, the database runs, tests run, and GitHub checks every change.

**New concepts:** Python virtual environments, FastAPI, settings from environment variables, liveness vs readiness, Alembic, Docker Compose, pub workspaces, GitHub Actions.

Before you start: complete the [setup guide](00-setup-your-machine.md) (Docker installed).

---

## 1.1 Create the repository skeleton

**Why:** a consistent layout from day one, so every later phase knows where things go.

**Do:**

```bash
cd ~/Desktop/flutter_ota_system
git init -b main
mkdir -p backend/app/api backend/app/models backend/tests/unit \
         packages app docs/{adr,architecture,api,protocol} .github/workflows
curl -fsSL https://www.apache.org/licenses/LICENSE-2.0.txt -o LICENSE
```

Create these small files:
- `.gitignore`: ignore `.venv/`, `__pycache__/`, `.pytest_cache/`, `.ruff_cache/`, `.env`, `*.pem`, `.dart_tool/`, `build/`, `.idea/`.
- `.editorconfig`: 2-space indent, 4 for `*.py`, tabs for `Makefile`.
- `.env.example`: shows the env vars (`OTA_ENV`, `OTA_DATABASE_URL`, `OTA_LOG_LEVEL`). The real `.env` is never committed.
- `NOTICE`: project name, copyright, "Licensed under Apache-2.0".
- `README.md`: one paragraph on what the project is, plus a quick start (fill in at the end of this phase).

**Check:** `git status` shows the files, and `.venv` or `.env` would be ignored.

---

## 1.2 Python project and virtual environment

**Why:** a **virtual environment** (`.venv`) keeps this project's Python packages separate from the system's. `pyproject.toml` lists what to install.

**Do:** create `backend/pyproject.toml` with:
- `[project]`: name `ota-backend`, `requires-python = ">=3.12"`, dependencies `fastapi`, `uvicorn[standard]`, `pydantic`, `pydantic-settings`, `sqlalchemy[asyncio]`, `asyncpg`, `alembic`.
- `[project.optional-dependencies] dev`: `pytest`, `pytest-asyncio`, `httpx`, `ruff`.
- `[tool.pytest.ini_options]`: `testpaths = ["tests"]`, `asyncio_mode = "auto"`.
- `[tool.ruff]`: `line-length = 100`, and lint rules `E, F, I, B, UP, ASYNC`.
- `[tool.setuptools.packages.find] include = ["app*"]` so `pip install -e .` finds the `app` package.

Then:

```bash
cd backend
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
```

`-e` (editable) means code changes apply immediately, without reinstalling.

**Check:** `.venv/bin/python -c "import fastapi; print(fastapi.__version__)"` prints a version.

---

## 1.3 Settings from environment variables

**Why:** no passwords or URLs hard-coded. Locally they come from `.env`, and in Azure the platform injects the same variables.

**Do:** `backend/app/config.py` with a `Settings(BaseSettings)` class using `env_prefix="OTA_"`. Fields to start with: `env` (local/test/dev/qa/staging/production), `log_level`, `database_url` (default `postgresql+asyncpg://ota:ota@localhost:5432/ota`), `db_pool_size`, `db_connect_timeout_seconds`. Add a cached `get_settings()` function (`@lru_cache`).

**Check:** `OTA_LOG_LEVEL=DEBUG .venv/bin/python -c "from app.config import get_settings; print(get_settings().log_level)"` prints `DEBUG`.

---

## 1.4 Logging and request IDs

**Why:**
- **JSON logs** can be searched in Azure Monitor.
- A **request ID** in every log line lets you find all lines for one failing request. It is returned to the caller in the `X-Request-ID` header.

**Do:**
- `app/logging.py`: a `ContextVar` holding the current request ID, a `JsonFormatter` that outputs `ts`, `level`, `logger`, `msg`, `request_id`, and a `configure_logging(level)` function.
- `app/middleware.py`: an HTTP middleware that uses the incoming `X-Request-ID` if it is safe (regex `^[A-Za-z0-9._-]{1,128}$`), otherwise generates a UUID. It stores it in the ContextVar and on `request.state`, and adds it to the response header. A client must not be able to inject newlines into your logs, which is why the regex matters.

---

## 1.5 Standard error format

**Why:** clients should parse every error the same way. Use RFC 9457 `application/problem+json`: `{type, title, status, instance, request_id, detail}`.

**Do:** `app/errors.py` with a `register_error_handlers(app)` that handles `HTTPException`, `RequestValidationError` (422) and any unexpected `Exception` (500, logged with traceback, **no internal details in the response**).

---

## 1.6 Database engine

**Do:** `app/db.py`:
- `create_engine(settings)` → `create_async_engine(url, pool_size=..., pool_pre_ping=True, connect_args={"timeout": ...})`
- `create_session_factory(engine)` → `async_sessionmaker(engine, expire_on_commit=False)`
- `get_session(request)`: a FastAPI dependency yielding one session per request from `request.app.state.session_factory`

Create `app/models/__init__.py` with an empty `class Base(DeclarativeBase)`. Phase 2 adds tables.

---

## 1.7 Health endpoints

**Why:**
- **Liveness** (`/healthz`): "is the process alive?" It never touches the database. If it fails, the platform restarts the container.
- **Readiness** (`/readyz`): "can it serve traffic?" It checks the database. If it fails, the platform stops sending traffic but does **not** restart.

Mixing them up means Azure restarts healthy containers every time the database blinks.

**Do:** `app/api/health.py` with an `APIRouter`:
- `GET /healthz` → `{"status":"ok","version":...}`
- `GET /readyz` → runs `SELECT 1` with a timeout. Returns 200 `{"database":"up"}`, or 503 `{"database":"down"}` on any error.

---

## 1.8 The application factory

**Why:** a `create_app(settings)` function (instead of a global app built at import) lets tests create an app with test settings.

**Do:** `app/main.py`:
- `create_app(settings=None)`: configure logging, and define a **lifespan** (startup: create engine and session factory on `app.state`; shutdown: `engine.dispose()`). Build `FastAPI(...)`, add the middleware and error handlers, and include the health router.
- `app = create_app()` at the bottom, for uvicorn.

**Check:**

```bash
.venv/bin/uvicorn app.main:app --reload
```

Open http://localhost:8000/docs → `/healthz` returns 200, and `/readyz` returns **503** (no database yet, which is correct).

---

## 1.9 First tests

**Do:** `tests/conftest.py` with:
- a `settings` fixture whose `database_url` points to `127.0.0.1:1` (a port that is never open, so database calls fail fast);
- a `client` fixture: `with TestClient(create_app(settings), raise_server_exceptions=False) as c: yield c`. The `with` runs the lifespan.

Write tests for:
1. `/healthz` returns 200 without a database
2. `/readyz` returns 503 when the database is down
3. a missing `X-Request-ID` → a UUID is generated
4. a safe incoming ID is echoed back
5. an unsafe ID (with a newline) is replaced
6. an unknown route → 404 with `content-type: application/problem+json` and the request ID in the body

**Check:** `.venv/bin/pytest -q` → 6 passed. `.venv/bin/ruff check . && .venv/bin/ruff format --check .` → clean.

---

## 1.10 Alembic (database migrations)

**Why:** you never change the database by hand. Every change is a versioned, reviewed file that runs the same way on your laptop and in production.

**Do:**

```bash
cd backend
.venv/bin/alembic init -t async migrations
```

Then edit:
- `alembic.ini`: remove the `sqlalchemy.url = ...` line.
- `migrations/env.py`: import `get_settings` and `Base`, then set
  `config.set_main_option("sqlalchemy.url", get_settings().database_url)` and `target_metadata = Base.metadata`.

Now the API and migrations read the same `OTA_DATABASE_URL`.

**Check:** `.venv/bin/alembic history` runs without errors (empty history).

---

## 1.11 Dockerfile

**Do:** `backend/Dockerfile`:
- `FROM python:3.13-slim`
- Copy `pyproject.toml` first and install dependencies. This layer stays cached when only code changes.
- Copy `app/`, `migrations/`, `alembic.ini`.
- Create and switch to a **non-root user**.
- `CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]`

Add `backend/.dockerignore` with `.venv`, `__pycache__`, `tests`, caches.

---

## 1.12 Docker Compose (the local stack)

**Do:** `docker-compose.yml` at the root with four services:

| Service | Image | Port | Notes |
|---|---|---|---|
| `postgres` | `postgres:16` | 5432 | user/password/db = `ota`. Named volume. **healthcheck** with `pg_isready` |
| `redis` | `redis:7-alpine` | 6379 | Used only if Phase 11 needs it |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | 10000 | `azurite-blob --blobHost 0.0.0.0 --loose`. Used from Phase 4 |
| `api` | `build: ./backend` | 8000 | `OTA_DATABASE_URL=...@postgres:5432/ota`. Command: `alembic upgrade head && uvicorn ...`. `depends_on: postgres: condition: service_healthy` |

Inside Compose, services reach each other by **service name** (`postgres`), not `localhost`.

**Check:**

```bash
docker compose up --build -d
docker compose ps                 # all running, postgres "healthy"
curl localhost:8000/readyz        # {"status":"ok","database":"up"}
docker compose logs -f api        # JSON log lines
docker compose exec postgres psql -U ota -d ota -c '\dt'   # alembic_version table
```

If a port is already in use, stop the other program or change the left-hand port number.

---

## 1.13 Makefile

**Why:** you don't have to remember long commands.

**Do:** a root `Makefile` with a self-documenting `help` target and: `backend-install`, `backend-run`, `backend-test`, `backend-lint`, `backend-format`, `migrate`, `migration m="..."`, `up`, `down`, `logs`, `flutter-get`, `flutter-test`, `test` (runs everything CI runs). Remember: Makefile recipes must be indented with **tabs**.

**Check:** `make help` lists the commands, and `make backend-test` passes.

---

## 1.14 Flutter pub workspace

**Why:** a **pub workspace** (Dart 3.6+) lets several packages share one dependency resolution: one `flutter pub get` at the root, and path dependencies between them.

**Do:**

```bash
dart create -t package packages/ota_protocol --no-pub
dart create -t package packages/ota_runtime_api --no-pub
flutter create --template=package packages/ota_client --no-pub
flutter create --org dev.flutterota --platforms=android,ios app/example_app --no-pub
```

Then:
1. Delete the generated sample code (the `Calculator` / `Awesome` classes, `example/` folders, sample tests).
2. Root `pubspec.yaml`: `name: flutter_ota_workspace`, `publish_to: none`, and `workspace:` listing the four package paths.
3. In **each** package's `pubspec.yaml`: add `resolution: workspace` and `publish_to: none`. Add path dependencies: `ota_runtime_api → ota_protocol`, `ota_client → ota_protocol + ota_runtime_api`, `example_app → ota_client`.
4. Minimal content so there is something to test:
   - `ota_protocol`: enums `PatchFormat` (`mock-v1`, `evc-v1`, `bidiff-aot-v1`, `runtime-v1`) and `NoUpdateReason` (the 7 reason codes), each with a `wire` string and a `fromWire` that returns `null` for unknown values (see [ADR-0003](phase-00-protocol-decisions.md)).
   - `ota_client`: a constant `otaClientSdkVersion = 'ota-client/0.1.0'`.
   - `example_app`: a screen showing the SDK version.
   - A test in each.

**Check:**

```bash
flutter pub get                 # at the root
dart analyze packages app       # No issues found
(cd packages/ota_protocol && dart test)
(cd packages/ota_client && flutter test)
(cd app/example_app && flutter test)
```

---

## 1.15 GitHub Actions CI

**Do:**
- `.github/workflows/backend-ci.yml`: on PR/push touching `backend/**`. Steps: checkout → `actions/setup-python@v5` (3.13) → `pip install -e ".[dev]"` → `ruff check` → `ruff format --check` → `pytest`. Set `permissions: contents: read`.
- `.github/workflows/flutter-ci.yml`: on PR/push touching `packages/**` or `app/**`. Steps: checkout → `subosito/flutter-action@v2` (stable) → `flutter pub get` → `dart format --set-exit-if-changed` → `dart analyze` → the tests.

**Check:** push to GitHub (setup S.4). Both workflows are green in the **Actions** tab.

---

## 1.16 Protect `main`

**Why:** no untested code reaches `main`, and you practise the pull-request flow.

**Do:** GitHub → Settings → Rules → new branch ruleset for `main`: require a pull request and require status checks from both workflows.

From now on: `git switch -c phase-2-...` → work → push → PR → merge when green.

---

## 1.17 Architecture overview

**Do:** an architecture overview (built as [docs/architecture.md](../architecture.md)) with the big-picture diagram from the [roadmap](README.md#target-architecture-planned) and one paragraph per component in your own words.

---

## Phase 1 is done when

- [ ] `make backend-test` and `make flutter-test` pass
- [ ] `make up` → `/readyz` returns 200
- [ ] Code is on GitHub, both CI workflows are green, and `main` is protected
- [ ] You can explain liveness vs readiness and control plane vs data plane
