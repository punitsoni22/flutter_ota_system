# Punit

**Self-hosted, experimental over-the-air (OTA) patch delivery for Flutter apps.**

> [!WARNING]
> **Punit is experimental alpha software (v0.1.0-alpha).**
>
> - It has been **tested internally only**, by its maintainers.
> - It has **not** been validated at production scale.
> - It has **not** undergone an independent security audit.
> - Punit distributes code and configuration that your app will run. A mistake in how you
>   operate it, or a bug in Punit, can break apps in the field or let an attacker ship code to
>   your users.
> - **Do not use Punit for production OTA delivery** until you have independently validated its
>   security, reliability, compatibility, rollback, signing and recovery for your own apps.
> - You run Punit **at your own risk** during the alpha period. See [LICENSE](LICENSE)
>   (Apache-2.0, sections 7 and 8: no warranty, no liability).

Punit is **self-hosted only**. There is no hosted Punit service. You run the server, store the
signing key and decide what gets shipped.

---

## Status

| Area | State in v0.1.0-alpha |
|---|---|
| Control plane (FastAPI + PostgreSQL) | Working, internally tested |
| Signed patch metadata (ES256) + SHA-256 | Working, covered by tests and `scripts/verify_demo.sh` |
| Channels, percentage rollout, rollback, revoke | Working, internally tested |
| `mock-v1` patches (signed, inert JSON/config that the app reads) | Working; used by the local demo |
| Android Dart code patches (`aot-bidiff-android-v1`, stock Flutter) | **Experimental.** Internally tested on a small number of devices. See [docs/code-push.md](docs/code-push.md) and its store-policy section |
| iOS code patches | **Not supported** (Apple forbids running downloaded native code; research notes only) |
| Storage | Local disk + nginx, or S3-compatible buckets (AWS S3, Cloudflare R2, Supabase Storage) |
| Azure Blob Storage / Azure Key Vault | **Not implemented** (planned; see roadmap) |
| Redis | **Not used** |
| Admin UI | One static page served by the API at `/admin` (single shared admin API key) |

## What Punit does

1. You register a **store release** of your app (e.g. `android 1.0.0+1`).
2. You upload a **patch** for that exact release. The server stores the file under its SHA-256
   and **signs** a canonical message describing it (app, release, patch number, platform, arch,
   format, hashes, size) with an ES256 key.
3. You **publish** the patch to a channel (`dev`, `staging`, `production`, ...) at a rollout
   percentage. Devices are bucketed deterministically, so 1% → 10% keeps the first 1%.
4. The `ota_client` Flutter package **checks** for updates, **downloads** the file directly
   from the CDN/object storage, verifies **size, SHA-256 and signature** against a public key
   compiled into the app, stages the patch and activates it on the next start.
5. If a patched app fails to start, the client **falls back** to the last good code on its own.
   You can also **roll back** or **revoke** a patch from the server.

## What Punit does NOT guarantee

- That a patch is safe, correct or compatible with your app. Punit checks *integrity and
  origin*, not *behaviour*.
- That OTA code patches are allowed for your app by Google Play, Apple or your contracts. You
  must check this yourself ([docs/code-push.md](docs/code-push.md)).
- Availability, durability or performance at any particular scale.
- Protection if your signing key or admin API key is stolen ([docs/security.md](docs/security.md)).
- Backward compatibility of the API, database schema or patch formats before v1.0.

## Architecture

```
 Flutter app + ota_client
   │  POST /v1/devices/register      (once; returns a device token)
   │  GET  /v1/updates/check         (metadata only: URL, sizes, hashes, signature)
   │  POST /v1/events/batch          (download / verify / boot outcomes)
   ▼
 FastAPI control plane ───────► PostgreSQL (apps, releases, patches, rollouts, devices, counters)
   │  signs patch metadata (ES256)
   │  writes immutable files
   ▼
 Object storage  ◄─── devices download patch bytes directly (nginx locally; CDN/bucket in prod)
```

Patch bytes never flow through FastAPI on the device path. Details:
[docs/architecture.md](docs/architecture.md).

## Tested platforms

What was actually exercised for this release:

- **Server (local stack):** Linux (Ubuntu) with Docker Engine + Compose v2, using `scripts/verify_demo.sh`.
- **Flutter:** `ota_client` analysis and unit tests with Flutter 3.44 stable. Requires Flutter ≥ 3.27 and Dart ≥ 3.12.
- **Devices:** Android emulator / devices, internal testing only. The maintainers have not
  published a device compatibility matrix.
- **Not tested:** macOS/Windows Docker Desktop hosts, iOS devices, production cloud deployments
  at scale.

## Prerequisites

- Git, Bash and `curl`
- Docker Engine 24+ or Docker Desktop, with **Compose v2** (`docker compose version`)
- Free ports `8000`, `8080` and `5432` on 127.0.0.1 (change them in `.env`)
- For the app: Flutter stable ≥ 3.27 and an Android emulator or device

## Quickstart (about 5–10 minutes)

```bash
git clone https://github.com/punitsoni22/flutter_ota_system.git
cd flutter_ota_system
cp .env.example .env                 # fake, local-only values
./scripts/setup_local.sh             # builds, creates a LOCAL dev signing key, starts the stack
docker compose ps                    # postgres, api, cdn: all "healthy"
./scripts/seed_demo.sh               # app punit-demo, channel dev, release android 1.0.0+1
./scripts/publish_test_patch.sh      # signed mock-v1 test patch, 100% of dev
./scripts/verify_demo.sh             # end-to-end checks; exits non-zero on any failure
```

`verify_demo.sh` registers a test device and checks for the patch. It then downloads the patch
from the local CDN and verifies its SHA-256 and ES256 signature. It confirms that corrupted
files and tampered signatures are rejected, then exercises rollback and revoke. Expected last
line:

```
RESULT: all checks passed (artifact pipeline; mock-v1 does not execute code)
```

Open the admin page at <http://localhost:8000/admin> and enter the `OTA_ADMIN_API_KEY` from your
`.env`. API docs are at <http://localhost:8000/docs>.

### Run the example app (Android emulator)

`seed_demo.sh` prints the exact `--dart-define` values, including the public key:

```bash
# in .env: OTA_CDN_BASE_URL=http://10.0.2.2:8080/cdn   then: docker compose up -d
cd example_app
flutter run \
  --dart-define=OTA_SERVER_URL=http://10.0.2.2:8000 \
  --dart-define=OTA_APP=punit-demo \
  --dart-define=OTA_CHANNEL=dev \
  --dart-define=OTA_PUBLIC_KEY=local-dev-1:<base64 point printed by seed_demo.sh>
```

The app shows "Store build (no patch)", downloads and verifies the patch in the background,
and on the next start shows the patch's banner and colour. A physical phone needs
`PUNIT_BIND_ADDRESS=0.0.0.0` and your laptop's LAN IP in both URLs. More:
[docs/mvp-testing.md](docs/mvp-testing.md).

### Clean up

```bash
./scripts/cleanup_local.sh   # deletes the local DB, patch files and the dev signing key
```

## Example patch flow (CLI)

```bash
python3 -m venv .venv && .venv/bin/pip install -r cli/requirements.txt
export OTA_API_URL=http://localhost:8000
export OTA_API_KEY=local-dev-admin-key-not-a-secret
alias ota=".venv/bin/python cli/ota.py"

echo '{"banner":"Fixed typo","color":"#1565C0"}' > patch.json
ota patch create punit-demo --platform android --release 1.0.0+1 --file arm64-v8a=patch.json
ota patch publish <patch_id> --channel dev --percent 100
ota patch rollout <patch_id> --channel production --percent 10
ota patch rollback <patch_id>     # devices return to the previous good patch or the store build
ota patch revoke <patch_id>       # permanent: never runs again
```

## API overview

| Purpose | Endpoint |
|---|---|
| Register device | `POST /v1/devices/register` |
| Check for update | `GET /v1/updates/check?platform&arch&release_version&channel&current_patch_number&supported_formats` |
| Device telemetry (also serves as the heartbeat) | `POST /v1/events/batch` |
| Patch download | the `download_url` from the update check (CDN / bucket, not the API) |
| Create app / list apps | `POST/GET /v1/admin/apps` |
| Create / list releases | `POST/GET /v1/admin/apps/{slug}/releases` |
| Create patch | `POST /v1/admin/releases/{release_id}/patches` + `POST /v1/admin/patches/{id}/artifacts` |
| Publish / change rollout | `POST /v1/admin/patches/{id}/publish`, `POST /v1/admin/patches/{id}/rollout` |
| Roll back / revoke | `POST /v1/admin/patches/{id}/rollback`, `POST /v1/admin/patches/{id}/revoke` |
| Devices (aggregated) | `GET /v1/admin/apps/{slug}/devices/summary` |
| Public signing key | `GET /v1/admin/signing-key` |
| Health | `GET /health/live`, `GET /health/ready` |

There is no per-device admin listing and no separate rollouts listing. Rollouts are shown per
patch (`GET /v1/admin/releases/{id}/patches`).

## Configuration

All server settings are environment variables prefixed `OTA_` (see
[backend/app/config.py](backend/app/config.py)):

| Variable | Purpose |
|---|---|
| `OTA_ENV` | `production` turns on startup safety checks (refuses default secrets, http CDN, SQLite, auto key generation) |
| `OTA_DATABASE_URL` | PostgreSQL URL (SQLite is for tests only) |
| `OTA_ADMIN_API_KEY` | Admin API key (`X-API-Key`) |
| `OTA_DEVICE_JWT_SECRET` | HMAC secret for device tokens |
| `OTA_ROLLOUT_HMAC_SECRET` | Rollout bucketing secret (changing it reshuffles cohorts) |
| `OTA_CDN_BASE_URL` | Public base URL devices download from |
| `OTA_STORAGE_BACKEND` | `local` or `s3` (+ `OTA_S3_*`) |
| `OTA_SIGNING_KEY_PATH` / `OTA_SIGNING_KEY_PEM` / `OTA_SIGNING_KEY_ID` | ES256 private key and its id |
| `OTA_AUTO_GENERATE_SIGNING_KEY` | Create a key at startup if missing (never in production) |

Local values live in `.env` (from [.env.example](.env.example)). For a single-VPS deployment,
see [deploy/](deploy/) and [docs/deploy.md](docs/deploy.md).

## Repository layout

```
backend/            FastAPI control plane, Alembic migrations, tests, /admin page
cli/                `ota` admin CLI and Android code-patch tooling (build, diff, upload)
packages/ota_client Flutter client package (check, download, verify, stage, boot protection)
example_app/        Example Flutter app using mock-v1 patches
docker/             nginx "CDN" config for the local stack
deploy/             Single-VPS production-style compose (Caddy + HTTPS)
scripts/            Local setup / demo / verification scripts
docs/               Architecture, security, ADRs, guides, release material
```

## Known limitations

- Alpha: API, schema and patch formats may change without migration paths.
- One shared admin API key; no users, roles, SSO or **audit log**.
- Device registration is open to anyone who knows the app slug. Device tokens limit what a
  device can see, but they do not prove the caller is a genuine install. There is no rate
  limiting.
- The signing key is a local PEM file or an environment variable. There is no HSM, Key Vault
  or KMS integration, and no key rotation workflow. Apps trust only the key ids compiled into
  them.
- Patch files are public, unauthenticated URLs (by content hash). Do not put secrets in patches.
- No Azure Blob adapter, no Redis cache, no separate admin frontend.
- Android code patches depend on Flutter internals and must exactly match the store build. Every
  Flutter upgrade needs a new store release.
- The maintainers have not published scale or load test results.

## Security

Read [docs/security.md](docs/security.md) before deploying anything. Report vulnerabilities
privately as described in [SECURITY.md](SECURITY.md), **never in public issues**.

## Roadmap (high level, not a commitment)

- Pluggable signers: Azure Key Vault / cloud KMS / HSM; key rotation with multiple trusted keys
- Azure Blob Storage adapter and short-lived download URLs
- Admin users, roles and an audit log
- Rate limiting and abuse controls on device endpoints
- Wider device test matrix and published load tests
- iOS research (interpreter-based patches), only if it can respect platform rules

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Licence

Apache License 2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Punit is not affiliated with or endorsed by Google, the Flutter project or Shorebird.
"Flutter" is a trademark of Google LLC.
