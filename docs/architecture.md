# Punit architecture

> Applies to v0.1.0-alpha. Punit is experimental; see the warning in the [README](../README.md).

## Components

```
┌──────────────────────────── device ────────────────────────────┐
│ Flutter app                                                    │
│   └─ ota_client (Dart)          check → download → verify →    │
│        └─ PatchRuntime          stage → activate on next start │
│        └─ Android plugin        native boot selection + boot   │
│           (OtaBoot.java)        protection for code patches    │
└────────────┬───────────────────────────────────┬───────────────┘
             │ control plane (small JSON)        │ data plane (patch bytes)
             ▼                                   ▼
┌──────────────────────────┐            ┌────────────────────────────┐
│ FastAPI (backend/app)    │──writes──► │ Object storage             │
│  device API  /v1/...     │            │  patches/<sha256>  public  │
│  admin API   /v1/admin   │            │  releases/<sha256> private │
│  /admin page             │            │ local: disk + nginx        │
│  signer (ES256)          │            │ prod: CDN / S3-compatible  │
└────────────┬─────────────┘            └────────────────────────────┘
             ▼
┌──────────────────────────┐
│ PostgreSQL               │  apps, channels, releases, release artifacts, patches,
│ (Alembic migrations)     │  patch artifacts + signatures, deployments, devices,
└──────────────────────────┘  event counters
```

| Component | Code | Notes |
|---|---|---|
| `ota_client` | `packages/ota_client/` | Pure Dart verification (SHA-256 via `crypto`, ES256 via `pointycastle`), state machine, telemetry |
| Example app | `example_app/` | Uses `MockPatchRuntime` (`mock-v1`) |
| Control plane | `backend/app/` | FastAPI, SQLAlchemy 2, Alembic, PyJWT, `cryptography` |
| Admin UI | `backend/app/admin.html` | Static page, calls the admin API with the key you type in |
| CLI / patch tooling | `cli/` | `ota` admin CLI; `android.py` builds, fingerprints and diffs Android releases; `otadiff.py` writes the `OTADIF01` diff format |
| Local CDN | `docker/nginx-cdn.conf` | Serves only `/cdn/patches/`, immutable caching; `releases/` is never exposed |
| Production-style deploy | `deploy/` | Single VPS: Postgres + API + nginx + Caddy (HTTPS) |

There is no separate `patch_engine` service and no worker process. Patch creation happens in
the CLI, and signing happens in the API when a patch file is uploaded.

## Update-check lifecycle

1. **Register** (`POST /v1/devices/register`). The app sends its slug, a random installation
   id, platform, arch, store version and channel. The server upserts a `devices` row and returns
   an HS256 **device token** (default 30 days) bound to the device id, app id and installation id.
2. **Check** (`GET /v1/updates/check`, bearer device token). The query carries `platform`,
   `arch`, `release_version`, `channel`, `current_patch_number`, `supported_formats` and
   `failed_patch_ids`. The server, in this order:
   1. Finds the **release** by (app, platform, version). If the store build is unknown, the
      answer is "no update".
   2. Collects patches of that release that are not drafts, and builds the **rolled-back** and
      **revoked** number lists. These go into every response.
   3. Keeps candidates that are `published` and have a **supported format**. A candidate needs a
      deployment on the device's **channel** and an artifact for its **arch**. It must not be in
      the device's failed list, and the device must fall inside the **rollout** percentage.
   4. Takes the highest patch number. It never offers an older patch than the one installed,
      unless the installed one was rolled back or revoked (**anti-replay**). In that case it
      sets `rollback_to_patch_number` (0 = store build).
   5. Returns metadata only: `download_url`, `size_bytes`, `base_artifact_sha256`,
      `payload_sha256`, `result_sha256`, `runtime_abi`, `signature`, `key_id`.
3. **Download** straight from `download_url`. The client stops if more than `size_bytes`
   arrive.
4. **Verify** on the device: the size must match and the SHA-256 must match `payload_sha256`.
   The `key_id` must be one compiled into the app, and the ES256 signature must verify over the
   canonical message ([ADR-0002](adr/0002-signature-scheme.md)). Code patches also check the
   base and result hashes.
5. **Stage and activate on the next start.** After the first frame plus a stability window the
   app confirms the boot. An unconfirmed start falls back to the last good code, and the patch
   is reported and skipped.
6. **Telemetry** (`POST /v1/events/batch`): downloaded, hash/signature failure, staged, boot
   succeeded/failed, auto-rollback. These are aggregated per patch into counters.

`_touch_device` updates `last_seen` at most hourly unless something changed, to keep writes
low. There is no separate heartbeat endpoint.

## Rollout

- `rollout_bps` (basis points, 0–10000) per (patch, channel).
- Bucket = `HMAC-SHA256(OTA_ROLLOUT_HMAC_SECRET, len-prefixed(app_id, installation_id, patch_id)) mod 10000`.
  This is deterministic, so increasing the percentage only adds devices. Changing the secret
  reshuffles every cohort.
- `rollback` sets the status to `rolled_back` (it can be re-published). `revoke` is permanent.
  Both reach devices on their next check.

## Signing system

- Algorithm: ECDSA P-256 / SHA-256 (ES256). The signature is raw `r||s`, base64.
- The signed message is `"OTA-PATCH-V1\n"` followed by length-prefixed fields: protocol
  version, application id, release id, patch number, platform, arch, runtime ABI, artifact
  format, base/payload/result SHA-256 and size. The device recomputes it from the metadata, so
  no field can be swapped without breaking the signature.
- `Signer` is a small interface (`backend/app/signing.py`). v0.1.0-alpha ships only
  `LocalSigner` (PEM file or `OTA_SIGNING_KEY_PEM`). A Key Vault/KMS signer would implement the
  same `sign()` / `public_key()` methods; **it is not implemented yet**.
- Apps embed `"<key_id>:<base64 uncompressed point>"`. Only those key ids are trusted.

## Storage: control plane vs data plane

- Files are **content-addressed** (`<kind>/<sha256>`) and immutable. Uploading the same bytes
  twice keeps the original.
- `patches/` is public (CDN / public bucket). `releases/` holds the store build's compiled code
  and stays private: the admin API serves it only to the CLI.
- At any real scale, **patch bytes must be served by object storage + CDN**, never streamed
  through FastAPI. The API answers small JSON update checks, and the CDN absorbs the burst of
  downloads after a publish. `OTA_SERVE_ARTIFACTS_LOCALLY=true` exists for single-tunnel local
  testing only, and production startup checks reject it.
- Backends: `LocalStorage` (disk, with nginx in front) and `S3Storage` (any S3-compatible
  service). **Azure Blob Storage is not implemented** in this release.

## Local vs production

| | Local (`docker-compose.yml`) | Production (your responsibility) |
|---|---|---|
| Secrets | Fake values from `.env.example` | Random 32+ char secrets from a secret manager; `OTA_ENV=production` |
| Signing key | Generated into Docker volume `punit_keys` by script | Created once, offline backup, ideally HSM/KMS (not yet supported) |
| Database | Postgres container, 127.0.0.1 | Managed/backed-up Postgres, TLS |
| Storage | Disk volume + nginx on :8080 | CDN in front of a bucket or disk, HTTPS only |
| Transport | HTTP on localhost | HTTPS everywhere (startup check requires an https CDN URL) |
| Admin | One key, `/admin` page | Restrict by network/VPN; rotate the key; there is no RBAC yet |
| Redis | Not used | Not used (an optional cache is on the roadmap) |

See [deploy.md](deploy.md) for the single-VPS setup and [security.md](security.md) before
exposing anything.

## Scale notes

The design keeps the hot path cheap. The update check is a few indexed queries, devices write
only when something changes, files are immutable and cacheable, and rollout needs no per-device
state. Earlier planning targeted large fleets, but **no load test results are published for
this release**. Treat any capacity figure as unverified.
