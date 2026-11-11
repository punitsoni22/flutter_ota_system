# Installation improvements

> **Roadmap status: 🚧 partly done.** Step 4 added a one-command local setup (`./flutter-ota-system.sh`), a
> hardened local Docker Compose stack and tested backup/restore for the local stack. The
> remaining items are open. Current instructions: [installation.md](../installation.md),
> [operations.md](../operations.md).

Status legend: ✅ done (tested on Linux) · 🚧 partly done · 🔭 open.

## Done or partly done in Step 4

| # | Gap | Status | What exists now |
|---|---|---|---|
| 2 | Four commands were needed for a demo | ✅ done | `./flutter-ota-system.sh setup` (checks, `.env`, build, dev key, start, health) and `./flutter-ota-system.sh demo` (seed, publish, verify). The old scripts still work |
| 3 | The `ota` CLI needed a manual virtual environment, an alias and two environment variables | 🚧 partly done | `./flutter-ota-system.sh cli` builds the wheel locally and installs it into `.venv-cli/`; `./flutter-ota-system.sh ota …` runs it against the local stack. Not on PyPI; public distribution is undecided. The CLI's top-level module names (`ota`, `android`, `otadiff`) should move into one package first |
| 4 | Phones needed manual `.env` edits | 🚧 partly done | A USB phone works with the default `.env` via `adb reverse` (tested on one Android 13 phone). A Wi-Fi phone still needs `OTA_CDN_BASE_URL` and `FLUTTER_OTA_BIND_ADDRESS` edits; no LAN-IP helper yet |
| 8 | No upgrade guide | 🚧 partly done | `./flutter-ota-system.sh update` (backup, rebuild, recreate; migrations on start) for the local stack, tested as a rebuild of the same version. An upgrade **between released versions** has not been tested |
| 9 | Backup and restore were not tested | 🚧 partly done | `./flutter-ota-system.sh backup` / `restore` for the local stack, tested with a round trip (database, files, signing key). `deploy/backup.sh` restore on a server is still untested |
| 10 | The `example_app` default slug was `demo`, the demo scripts used `flutter-ota-system-demo` | ✅ done | The example app now defaults to `flutter-ota-system-demo`; tested on an Android phone without `--dart-define=OTA_APP` |
| 13 | Local secrets were fixed example values | ✅ done | `setup` writes random local values into a new `.env` (mode 600) and never changes an existing one |
| 14 | Postgres was published on a host port | ✅ done | Postgres is on an internal network; a host port is opt-in (`docker/compose.postgres-port.yml`) |
| 15 | Image versions floated (`postgres:17-alpine`, …) | ✅ done | Pinned: `postgres:17.11-alpine`, `nginx:1.27.5-alpine`, `python:3.13.18-slim-trixie` (multi-stage API image), `caddy:2.8.4-alpine` (single-server draft) |

## Still open

| # | Gap today | Proposed improvement |
|---|---|---|
| 1 | The local quickstart is tested on Linux only. macOS and Windows (including Docker Desktop and WSL2) are **not tested** | Test on macOS and Windows (Docker Desktop) and document differences (🔭 open) |
| 5 | The single-server production setup (`deploy/`) has **not been verified end to end** | Test it from a clean server; turn it into a documented, tested "server quickstart" (🔭 open) |
| 6 | Production signing-key creation and backup are manual | A guided first-run command, with backup instructions and a check that the key exists (🔭 open) |
| 7 | No pre-built images; users build from source | Optionally publish images, **after** the licence duties in [THIRD_PARTY_NOTICES.md §7](../../THIRD_PARTY_NOTICES.md#7-future-actions-before-publishing-pre-built-docker-images) are done (🔭 open) |
| 11 | `ota_client` is not published on pub.dev; apps use a git or path dependency | Decide on publishing, versioning and tags (🔭 open) |
| 12 | The app side is tested on Android only, on a small number of devices. iOS is **not tested** (needs macOS + Xcode) | Build and run the example app on iOS; test more Android devices, OS versions and ABIs; test more Flutter versions (🔭 open, see [Platform testing](README.md#platform-testing-planned)) |
| 16 | Python dependencies of the API image use minimum versions (`>=`), not a lock file | Add a lock file (e.g. `pip-compile` with hashes) so image builds are reproducible (🔭 open) |
| 17 | The emulator and Wi-Fi phone paths were not re-tested with `flutter-ota-system.sh` | Re-test both and record the result (🔭 open) |
