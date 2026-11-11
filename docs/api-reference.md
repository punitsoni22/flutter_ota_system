# API reference

All endpoints of the Flutter OTA System server v0.1.0-alpha, taken from
[`backend/app/routers/`](../backend/app/routers/), [`main.py`](../backend/app/main.py) and the
schemas in [`schemas.py`](../backend/app/schemas.py).

**OpenAPI.** When `OTA_ENV` is not `production`, the server publishes its generated spec at
`/openapi.json` and interactive docs at `/docs` (local stack: <http://localhost:8000/docs>). They
are switched off in production.

**Stability.** This is an alpha API. Endpoints and fields may change before v1.0.

## Conventions

| Topic | Rule |
|---|---|
| Base URL | Your server, e.g. `http://localhost:8000` locally |
| Body format | JSON (`Content-Type: application/json`), except uploads and channel creation, which use `multipart/form-data` |
| IDs | UUID strings |
| Times | ISO 8601 with time zone, e.g. `2026-11-10T18:36:25.147803Z` |
| Errors | `{"detail": "<message>"}`. Validation errors (HTTP 422) return `{"detail": [ {type, loc, msg, input}, … ]}` |

```json
{"detail":[{"type":"missing","loc":["body","installation_id"],"msg":"Field required","input":{"app":"flutter-ota-system-demo"}}]}
```

### Authentication

| Caller | How | Used for |
|---|---|---|
| Device | `Authorization: Bearer <access_token>` from `POST /v1/devices/register` | `/v1/updates/check`, `/v1/events/batch` |
| Admin (CLI, CI, admin page) | `X-API-Key: <OTA_ADMIN_API_KEY>` | everything under `/v1/admin` |
| None | — | `/v1/devices/register`, `/health/*`, `/admin` (the page itself) |

| Auth error | Status | `detail` |
|---|---|---|
| No device token | 401 | `Missing device token` |
| Bad or expired device token | 401 | `Invalid device token` |
| No or wrong admin key | 401 | `Invalid or missing X-API-Key` |

There is no rate limiting.

---

## Device API

### Register a device

`POST /v1/devices/register` · no auth

Creates the device, or updates it if this `installation_id` is already known for the app
(idempotent), and returns a device token.

| Body field | Type | Rules |
|---|---|---|
| `app` | string | Application slug, `^[a-z0-9][a-z0-9-]{1,98}[a-z0-9]$` |
| `installation_id` | string | 8–128 characters, chosen by the client and kept for the install |
| `platform` | string | `android` or `ios` |
| `arch` | string | `^[a-z0-9_-]{2,32}$`, e.g. `arm64-v8a` |
| `release_version` | string | 1–64 characters, e.g. `1.0.0+1` |
| `channel` | string | max 64, default `production` |

Response `200`:

```json
{
  "device_id": "1ff6836a-f431-4e35-9926-031c40500431",
  "access_token": "<device JWT>",
  "expires_in": 2592000
}
```

Errors: `404 Unknown application`, `422` validation.

```bash
curl -X POST http://localhost:8000/v1/devices/register \
  -H 'Content-Type: application/json' \
  -d '{"app":"flutter-ota-system-demo","installation_id":"docs-example-0001","platform":"android","arch":"arm64-v8a","release_version":"1.0.0+1","channel":"dev"}'
```

### Check for an update

`GET /v1/updates/check` · device token

Returns patch **metadata** only; the bytes are downloaded from `download_url`. The decision is
described in [architecture.md](architecture.md#device-registration-and-the-update-check).

| Query parameter | Required | Rules / default |
|---|---|---|
| `platform` | yes | `android` or `ios` |
| `arch` | yes | `^[a-z0-9_-]{2,32}$` |
| `release_version` | yes | 1–64 characters |
| `channel` | no | default `production` |
| `current_patch_number` | no | ≥ 0, default `0` (store build) |
| `supported_formats` | no | comma-separated, default `mock-v1` |
| `failed_patch_ids` | no | comma-separated patch ids that crashed on this device; they are skipped |

Response `200` (`UpdateCheckOut`):

| Field | Meaning |
|---|---|
| `update_available` | `true` if `patch` should be downloaded |
| `application_id`, `release_id` | Server ids. `release_id` is `null` if the release is unknown |
| `patch` | `null`, or the offered patch (below) |
| `rollback_to_patch_number` | Set when the device's current patch is bad: the number to go back to (`0` = store build) |
| `rolled_back_patch_numbers`, `revoked_patch_numbers` | Always present: bad patches of this release |
| `next_check_after_seconds` | Suggested interval (`OTA_CHECK_INTERVAL_SECONDS`) |

`patch` fields: `id`, `number`, `artifact_format`, `arch`, `runtime_abi`, `download_url`,
`base_artifact_sha256` (all zeros for `mock-v1`), `payload_sha256`, `result_sha256`,
`size_bytes`, `signature` (base64 raw r‖s), `key_id`. What is signed:
[security.md](security.md#what-is-signed).

Example (local demo):

```bash
curl "http://localhost:8000/v1/updates/check?platform=android&arch=arm64-v8a&release_version=1.0.0%2B1&channel=dev&current_patch_number=0&supported_formats=mock-v1" \
  -H "Authorization: Bearer $TOKEN"
```

```json
{
  "update_available": true,
  "application_id": "12ebc1fd-abb9-4ee3-83c3-78deb9fadaa8",
  "release_id": "407f4027-b2e8-4a21-a6fc-4fe3d3615282",
  "patch": {
    "id": "b1d78a59-3871-42d3-ad7b-fa26cb07b603",
    "number": 1,
    "artifact_format": "mock-v1",
    "arch": "arm64-v8a",
    "runtime_abi": "ota-runtime-v1",
    "download_url": "http://localhost:8080/cdn/patches/77d5f7ab699ed17dd422a1bfc59ded567561ca89076fc44442d65fda2b982917",
    "base_artifact_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "payload_sha256": "77d5f7ab699ed17dd422a1bfc59ded567561ca89076fc44442d65fda2b982917",
    "result_sha256": "77d5f7ab699ed17dd422a1bfc59ded567561ca89076fc44442d65fda2b982917",
    "size_bytes": 63,
    "signature": "4nKrYOLyMtRsO7g91yDdqnrmwhBRJRHUmcrBiTXenmJmJvbTCQOC2q7fJ3e7h3lvrpIyi/MBh1TASbnTRe21+w==",
    "key_id": "local-dev-1"
  },
  "rollback_to_patch_number": null,
  "rolled_back_patch_numbers": [],
  "revoked_patch_numbers": [2],
  "next_check_after_seconds": 1800
}
```

Errors: `401` (token), `422` validation. An unknown release or channel is **not** an error: the
answer is `update_available: false`.

### Report device events

`POST /v1/events/batch` · device token

Counts boot and install outcomes per patch. Unknown patch ids, and patch ids of another
application, are ignored.

| Body field | Rules |
|---|---|
| `events` | list, at most 100 items |
| `events[].type` | `patch_downloaded`, `patch_hash_failed`, `patch_signature_failed`, `patch_staged`, `patch_boot_succeeded`, `patch_boot_failed`, `patch_auto_rollback` |
| `events[].patch_id` | 36-character patch id |

Response `202`: `{"accepted": <number of events received>}`. Errors: `401`, `422`.

```bash
curl -X POST http://localhost:8000/v1/events/batch \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"events":[{"type":"patch_boot_succeeded","patch_id":"b1d78a59-3871-42d3-ad7b-fa26cb07b603"}]}'
```

### Download a patch

`GET <download_url>` · no auth

Not an API endpoint: the file server or bucket serves `OTA_CDN_BASE_URL/patches/<sha256>` with
`Cache-Control: public, max-age=31536000, immutable`. Anything else under `/cdn/` returns 404.

---

## Admin API

Every endpoint below needs `X-API-Key`. All return `401 Invalid or missing X-API-Key` without it.

### Objects

**`AppOut`**: `id`, `slug`, `name`, `distribution` (`enterprise` \| `public_store`),
`aot_policy_approved` (bool), `policy_reason` and `policy_updated_at` (the latest approval or
withdrawal; `null` if never set), `created_at`.

**`ReleaseOut`**: `id`, `application_id`, `platform`, `version`, `flutter_version`,
`engine_revision`, `runtime_abi`, `fingerprint` (object), `created_at`, `artifacts`
(list of `{arch, sha256, size_bytes, url}`; `url` is the admin download path).

**`PatchOut`**: `id`, `release_id`, `release_version`, `platform`, `number`,
`artifact_format`, `status` (`draft` \| `published` \| `rolled_back` \| `revoked`), `note`,
`created_at`, `artifacts` (list of `{arch, base_artifact_sha256, payload_sha256, result_sha256,
size_bytes, signature, key_id, url}`), `deployments` (list of `{channel, rollout_percent}`),
`event_counts` (`{event_type: count}`).

Example `PatchOut` (local demo):

```json
{
  "id": "b1d78a59-3871-42d3-ad7b-fa26cb07b603",
  "release_id": "407f4027-b2e8-4a21-a6fc-4fe3d3615282",
  "release_version": "1.0.0+1",
  "platform": "android",
  "number": 1,
  "artifact_format": "mock-v1",
  "status": "published",
  "note": "Flutter OTA System demo test patch",
  "created_at": "2026-11-10T18:36:27.035124Z",
  "artifacts": [
    {
      "arch": "arm64-v8a",
      "base_artifact_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "payload_sha256": "77d5f7ab699ed17dd422a1bfc59ded567561ca89076fc44442d65fda2b982917",
      "result_sha256": "77d5f7ab699ed17dd422a1bfc59ded567561ca89076fc44442d65fda2b982917",
      "size_bytes": 63,
      "signature": "4nKrYOLy…Re21+w==",
      "key_id": "local-dev-1",
      "url": "http://localhost:8080/cdn/patches/77d5f7ab…2b982917"
    }
  ],
  "deployments": [{"channel": "dev", "rollout_percent": 100.0}],
  "event_counts": {}
}
```

### Applications and channels

| Method and path | Body | Success | Errors |
|---|---|---|---|
| `POST /v1/admin/apps` | JSON `{slug, name, distribution?}`. `slug` pattern as above; `name` 1–200; `distribution` default `enterprise` | `201 AppOut`. Also creates channels `dev`, `staging`, `production` | `409 Application '<slug>' already exists`, `422` |
| `GET /v1/admin/apps` | — | `200 [AppOut]` | — |
| `POST /v1/admin/apps/{slug}/policy-approval` | JSON `{approved: bool, reason: string (3–1000)}`. Each call is stored with its reason and time ([KI-2](known-issues.md#ki-2-the-policy-approval-reason-is-not-stored), fixed) | `200 AppOut` | `404 Application '<slug>' not found`, `422` |
| `GET /v1/admin/apps/{slug}/policy-approvals` | — | `200 [{approved, reason, created_at}]`, newest first | `404` |
| `GET /v1/admin/apps/{slug}/channels` | — | `200 ["dev","staging","production"]` | `404` |
| `POST /v1/admin/apps/{slug}/channels` | **form** field `name`, `^[a-z0-9-]{1,64}$` | `201` list of channel names | `404`, `409 Channel already exists`, `422` |
| `GET /v1/admin/apps/{slug}/devices/summary` | — | `200 [{platform, release_version, channel, patch_number, devices}]`, grouped from each device's last check | `404` |

```bash
curl -X POST -H "X-API-Key: $OTA_API_KEY" -F name=qa http://localhost:8000/v1/admin/apps/flutter-ota-system-demo/channels
# ["dev","staging","production","qa"]
```

### Releases

| Method and path | Body | Success | Errors |
|---|---|---|---|
| `POST /v1/admin/apps/{slug}/releases` | JSON `{platform, version, flutter_version?, engine_revision?, runtime_abi? (default "ota-runtime-v1"), fingerprint? (object, ≤ 256 kB), replace? (default false)}` | `201 ReleaseOut` | `404`, `409 Release <platform> <version> already exists`, `409 <n> device(s) still report <platform> <version> from a deleted release…` (send `replace: true` to register it anyway; [KI-1](known-issues.md#ki-1-re-creating-a-deleted-release-breaks-existing-installs)), `422` |
| `GET /v1/admin/apps/{slug}/releases` | — | `200 [ReleaseOut]` | `404` |
| `POST /v1/admin/releases/{release_id}/artifacts` | **form** `arch` + file `file`. The base file patches are diffed against (`libapp.so`) | `201 ReleaseOut` | `404 Release not found`, `409 Release already has a <arch> artifact` |
| `GET /v1/admin/releases/{release_id}/artifacts/{arch}` | — | `200` file bytes (`application/octet-stream`) | `404 Release has no <arch> artifact` |
| `DELETE /v1/admin/releases/{release_id}` | — | `204` (release, patches, deployments and counters removed; stored files kept) | `404`, `409 Roll back or revoke its published patches first` |

### Patches

| Method and path | Body | Success | Errors |
|---|---|---|---|
| `POST /v1/admin/releases/{release_id}/patches` | JSON `{artifact_format? (default "mock-v1"), note? (≤ 2000)}`. Formats: `mock-v1`, `aot-bidiff-android-v1`, `evc-v1` | `201 PatchOut` (`draft`, next number) | `404`, `422 AOT patches are Android-only`, `409 Could not allocate a patch number, retry` |
| `GET /v1/admin/releases/{release_id}/patches` | — | `200 [PatchOut]` ordered by number | `404` |
| `GET /v1/admin/patches/{patch_id}` | — | `200 PatchOut` | `404 Patch not found` |
| `POST /v1/admin/patches/{patch_id}/artifacts` | **form** `arch`, file `file`, `result_sha256?` (64 lowercase hex). The server stores the file and **signs** the artifact | `201 PatchOut` | `404`, `409 Artifacts can only be added to a draft patch`, `409 Patch already has a <arch> artifact`, `422` (AOT: base artifact missing, or `result_sha256` missing/invalid) |
| `POST /v1/admin/patches/{patch_id}/publish` | JSON `{channel, rollout_percent (0–100), force? (default false), reason? (≤ 1000)}` | `200 PatchOut` (`published`) | `404`, `409 Cannot publish a <status> patch` (only `draft`/`rolled_back`), `409 promotion_checks_failed: …`, `422 Patch has no artifacts`, `422 force=true needs a reason (3+ characters)`, `403 policy_review_required: …` |
| `POST /v1/admin/patches/{patch_id}/rollout` | JSON `{channel, rollout_percent, force?, reason?}` | `200 PatchOut` | `404` (patch or `Channel '<name>' not found`), `409 Only published patches have a rollout`, `409 promotion_checks_failed: …`, `422 force=true needs a reason (3+ characters)` |
| `POST /v1/admin/patches/{patch_id}/rollback` | — | `200 PatchOut` (`rolled_back`) | `404`, `409 Cannot roll back a <status> patch` |
| `POST /v1/admin/patches/{patch_id}/revoke` | — | `200 PatchOut` (`revoked`, final) | `404`, `409 Patch is already revoked` |

`rollout_percent` is stored as basis points (`round(percent × 100)`), so the smallest step is
0.01%. `publish` and `rollout` create the deployment for that channel if it does not exist yet.

**Promotion checks** ([KI-4](known-issues.md#ki-4-promote-safety-checks-are-enforced-only-by-the-cli), fixed): when `channel` is protected
(`OTA_PROTECTED_CHANNELS`, default `production`) and the new percentage is higher than the
current one, the server requires (1) a deployment above 0% on another, unprotected channel, or
already on this channel, and (2) no `patch_boot_failed` events. Otherwise it answers `409
promotion_checks_failed: patch #N: <problems>`. `force: true` with a `reason` skips the checks; the
server logs the override with the reason (there is no audit log yet). Lowering a percentage is
never checked.

```bash
curl -X POST http://localhost:8000/v1/admin/patches/$PATCH_ID/rollout \
  -H "X-API-Key: $OTA_API_KEY" -H 'Content-Type: application/json' \
  -d '{"channel":"production","rollout_percent":5}'
```

### Signing key

`GET /v1/admin/signing-key` → `200 {key_id, algorithm: "ES256", uncompressed_point_base64, pem}`.
The **public** key to embed in apps. The private key is never returned.

---

## Health and pages

| Method and path | Auth | Response |
|---|---|---|
| `GET /health/live` | none | `200 {"status":"ok"}` while the process runs |
| `GET /health/ready` | none | `200 {"status":"ok"}` when the database answers; an error status if it does not |
| `GET /admin` | none for the page | The static admin page. It calls the admin API with the key you type in |
| `GET /docs`, `GET /openapi.json` | none | Only when `OTA_ENV` is not `production` |
| `GET /cdn/patches/<sha256>` on the API | none | Only when `OTA_SERVE_ARTIFACTS_LOCALLY=true` with `local` storage |
