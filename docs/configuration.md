# Configuration reference

Punit is configured only through **environment variables**. This page lists all of them, taken
from [`backend/app/config.py`](../backend/app/config.py), the Compose files, the CLI and the
Dockerfile.

## Server settings (`OTA_*`)

The API reads every variable that starts with `OTA_`. It also reads a `.env` file in its working
directory if one exists.

"Default" is the value in `config.py`, used when the API runs **without** Docker (for example
in tests). The local Docker stack overrides several of them; see the next column.

| Variable | Default (`config.py`) | Local Docker stack | Purpose |
|---|---|---|---|
| `OTA_ENV` | `development` | `development` | `production` turns on the startup safety checks (below) and **turns off** `/docs` and `/openapi.json` |
| `OTA_DATABASE_URL` | SQLite file `backend/data/ota.db` | Postgres container | Database URL. `postgres://` and `postgresql://` are rewritten to use the psycopg 3 driver. SQLite is for tests only |
| `OTA_DB_POOL_SIZE` | `10` | `10` | Database connections per worker (overflow = 2 × this) |
| `OTA_ADMIN_API_KEY` | `dev-admin-key` | from `.env` | The admin key (`X-API-Key` header) for the CLI, CI and `/admin` page |
| `OTA_DEVICE_JWT_SECRET` | `dev-device-jwt-secret-change-me` | from `.env` | HMAC secret for device tokens (HS256). Changing it makes every device re-register |
| `OTA_DEVICE_TOKEN_TTL_SECONDS` | `2592000` (30 days) | default | Lifetime of a device token |
| `OTA_ROLLOUT_HMAC_SECRET` | `dev-rollout-secret-change-me` | from `.env` | Secret for rollout buckets. **Changing it reshuffles every rollout group** |
| `OTA_CHECK_INTERVAL_SECONDS` | `1800` | default | `next_check_after_seconds` sent to devices. The client adds ±20% jitter |
| `OTA_STORAGE_BACKEND` | `local` | `local` | `local` (disk) or `s3` (S3-compatible buckets) |
| `OTA_STORAGE_DIR` | `backend/data/artifacts` | `/data/artifacts` (volume) | Where `local` storage keeps files |
| `OTA_CDN_BASE_URL` | `http://127.0.0.1:8000/cdn` | from `.env` (`http://localhost:8080/cdn`) | Public base URL devices download patches from. Download URLs are `<this>/patches/<sha256>` |
| `OTA_SERVE_ARTIFACTS_LOCALLY` | `true` | `false` | `true`: FastAPI itself serves `/cdn/patches` (only with `local` storage). For runs without nginx only |
| `OTA_S3_ENDPOINT_URL` | empty | — | S3 endpoint, e.g. a Cloudflare R2 or Supabase Storage S3 URL. Empty = AWS default |
| `OTA_S3_REGION` | `auto` | — | S3 region |
| `OTA_S3_ACCESS_KEY_ID` / `OTA_S3_SECRET_ACCESS_KEY` | empty | — | S3 credentials |
| `OTA_S3_SESSION_TOKEN` | empty | — | Optional S3 session token |
| `OTA_S3_PUBLIC_BUCKET` | `ota-public` | — | Bucket for `patches/` (must be publicly readable at `OTA_CDN_BASE_URL`) |
| `OTA_S3_PRIVATE_BUCKET` | `ota-private` | — | Bucket for `releases/` (must **not** be public) |
| `OTA_SIGNING_KEY_PEM` | empty | — | The ES256 private key itself, as PEM. One line with `\n` escapes is accepted. Takes priority over the key file |
| `OTA_SIGNING_KEY_PATH` | `backend/data/keys/ota_signing_private.pem` | `/data/keys/ota_signing_private.pem` (volume `punit_keys`) | Key file used when `OTA_SIGNING_KEY_PEM` is empty |
| `OTA_SIGNING_KEY_ID` | `dev-1` | `local-dev-1` | Name of the key. Apps trust keys by this id |
| `OTA_AUTO_GENERATE_SIGNING_KEY` | `true` | `false` | Create a key at startup if the file is missing. Must be `false` in production |

### Production safety checks

With `OTA_ENV=production`, the API **refuses to start** and logs `Unsafe production settings:` with
a list, if any of these is true:

- `OTA_ADMIN_API_KEY`, `OTA_DEVICE_JWT_SECRET` or `OTA_ROLLOUT_HMAC_SECRET` is the built-in
  default or shorter than 32 characters;
- `OTA_AUTO_GENERATE_SIGNING_KEY` is `true` and `OTA_SIGNING_KEY_PEM` is empty;
- `OTA_STORAGE_BACKEND=s3` without an access key id and secret;
- `OTA_CDN_BASE_URL` does not start with `https://`;
- `OTA_DATABASE_URL` is SQLite;
- `OTA_SERVE_ARTIFACTS_LOCALLY=true` with `local` storage.

Generate random values with `openssl rand -hex 32`.

## Container settings

Read by the API image's start command ([`backend/Dockerfile`](../backend/Dockerfile)):

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8000` | Port Uvicorn listens on inside the container |
| `WEB_CONCURRENCY` | `2` | Number of Uvicorn worker processes |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` | Proxies trusted for `X-Forwarded-*` headers. The single-server compose sets `*` because only Caddy can reach the API |

## Local stack settings (`.env`, Docker Compose)

Read by [`docker-compose.yml`](../docker-compose.yml) and the scripts. Copy
[`.env.example`](../.env.example) to `.env`. All example values are fake and local-only.

| Variable | Example value | Purpose |
|---|---|---|
| `PUNIT_API_PORT` | `8000` | Host port for the API |
| `PUNIT_CDN_PORT` | `8080` | Host port for the nginx file server |
| `PUNIT_POSTGRES_PORT` | `5432` | Host port for Postgres (always bound to 127.0.0.1) |
| `PUNIT_BIND_ADDRESS` | not set (= `127.0.0.1`) | Set `0.0.0.0` to let phones on your network reach the API and file server |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `punit` / fake / `punit` | Local database credentials |
| `OTA_ENV`, `OTA_ADMIN_API_KEY`, `OTA_DEVICE_JWT_SECRET`, `OTA_ROLLOUT_HMAC_SECRET`, `OTA_CDN_BASE_URL`, `OTA_SERVE_ARTIFACTS_LOCALLY`, `OTA_SIGNING_KEY_ID`, `OTA_AUTO_GENERATE_SIGNING_KEY` | see `.env.example` | Passed to the API (see above) |
| `PUNIT_DEMO_APP`, `PUNIT_DEMO_CHANNEL`, `PUNIT_DEMO_RELEASE`, `PUNIT_DEMO_PLATFORM`, `PUNIT_DEMO_ARCH` | `punit-demo`, `dev`, `1.0.0+1`, `android`, `arm64-v8a` | What the demo scripts create and test |

The scripts refuse to run when `.env` contains `OTA_ENV=production`.

### Which `OTA_CDN_BASE_URL`?

| Who downloads | Value |
|---|---|
| Scripts, desktop, iOS simulator | `http://localhost:8080/cdn` |
| Android emulator | `http://10.0.2.2:8080/cdn` |
| Phone on your Wi-Fi | `http://<computer-LAN-IP>:8080/cdn` (+ `PUNIT_BIND_ADDRESS=0.0.0.0`) |
| Production | `https://<your-domain>/cdn` |

Apply changes with `docker compose up -d`.

## Single-server deployment settings (`deploy/.env`)

Read by [`deploy/docker-compose.prod.yml`](../deploy/docker-compose.prod.yml), from
[`deploy/.env.example`](../deploy/.env.example). This setup is a **draft that has not been
verified end to end** ([operations.md](operations.md#single-server-deployment-draft)).

| Variable | Purpose |
|---|---|
| `OTA_DOMAIN` | Your server's domain. Caddy gets an HTTPS certificate for it; `OTA_CDN_BASE_URL` becomes `https://<domain>/cdn` |
| `POSTGRES_PASSWORD` | Database password (random) |
| `OTA_ADMIN_API_KEY`, `OTA_DEVICE_JWT_SECRET`, `OTA_ROLLOUT_HMAC_SECRET` | Random, 32+ characters |
| `OTA_SIGNING_KEY_ID` | Key name, default `prod-1` |

That compose file fixes `OTA_ENV=production`, `OTA_AUTO_GENERATE_SIGNING_KEY=false` and
`OTA_SERVE_ARTIFACTS_LOCALLY=false`.

## CLI settings

Read by [`cli/ota.py`](../cli/ota.py) and [`cli/android.py`](../cli/android.py):

| Variable | Default | Purpose |
|---|---|---|
| `OTA_API_URL` | `http://127.0.0.1:8000` | Server address |
| `OTA_API_KEY` | `dev-admin-key` | Admin key. Must equal the server's `OTA_ADMIN_API_KEY` |
| `FLUTTER` | `flutter` | Flutter command used by `ota release android` / `ota patch android` |

## App build settings (`--dart-define`)

`ota_client` itself reads no environment variables: you pass everything in `OtaConfig`
([flutter-integration.md](flutter-integration.md)). The example app and the integration helper in
that guide use these build-time values:

| Name | Example | Purpose |
|---|---|---|
| `OTA_SERVER_URL` | `https://ota.example.com` | Server address. In the helper, empty = OTA off |
| `OTA_PUBLIC_KEY` | `prod-1:BIi7…` | `<key_id>:<base64 uncompressed P-256 point>` from `ota key show` |
| `OTA_CHANNEL` | `staging` | Channel of this build (default `production`) |
| `OTA_APP` | `punit-demo` | Example app only: the application slug |
