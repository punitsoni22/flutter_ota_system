<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Backend protocol: developer-signed patches (`dbc-v1`)

Contributor reference for the backend side of the bytecode architecture (added in Phase 4; the
file name is kept because source comments link to it). Status: experimental alpha, Android only.
The endpoint list is in the [API reference](../api-reference.md).

## 1. The idea in one paragraph

For the new `dbc-v1` format, the **developer** signs the patch on their own machine. The server
**never signs** a `dbc-v1` patch and needs no private key for it. The server only **checks** the
patch when it is uploaded (with the same rules the phone uses), stores the file **unchanged**,
and hands it to phones. The phone checks it again before it runs it.

The older formats (`mock-v1`, `aot-bidiff-android-v1`) keep working exactly as before: the server
signs them, and old apps see exactly the same responses as before.

## 2. The patch file

A `dbc-v1` patch is one `OTAPRT02` container:

```
"OTAPRT02" | u32 big-endian manifest length | manifest (canonical JSON)
           | u32 big-endian signature length | signature block (canonical JSON)
           | module bytes (Dart bytecode)
```

- **Canonical JSON:** UTF-8, keys sorted, no spaces, whole numbers only (no floats).
- **Limits:** whole file at most 8 MiB, manifest at most 64 KiB, signature block at most 8 KiB.
  A bigger upload is refused with HTTP 413.
- **Module size:** must equal `manifest.module.size`. Extra bytes after the module are refused
  (`trailing_data`); missing bytes are refused (`wrong_size`).
- **Signature block:** `{"alg":"ES256","key_id":..., "sig":..., "cert":{...}, "approvals":[...]}`.
  `sig` is raw `r||s` (64 bytes), base64. It signs
  `"flutter-ota-system/patch-manifest/v2\n" + manifest bytes`. `cert` is **required** for `dbc-v1`.

The manifest fields are the Phase 3 manifest v2 (`format`, `app_id`, `release_id`,
`baseline_libapp_sha256`, `patch_id`, `sequence`, `key_id`, `created_at`, optional `expires_at`,
`runtime`, `module`, `packages`, `host_interface`, `assets`, `toolchain`). Unknown fields are refused.

### Which ids go into the manifest

| Manifest field | Must equal |
| --- | --- |
| `app_id` | the application's id on the server (UUID) |
| `release_id` | the release's id on the server (UUID). The CLI may choose this id itself when it creates the release (`"id"` in the create-release request), so it can compile it into the app before the build |
| `baseline_libapp_sha256` | the SHA-256 of the release's base file (`libapp.so`) for the uploaded arch |

## 3. Trust chain

```
app ROOT key (private key offline, with the developer; public key registered on the server
              and compiled into the app)
  └── signs a KEY CERTIFICATE for a signer (or approver) key
        └── the certified signer key signs the patch manifest
app ROOT key also signs REVOCATION LISTS
```

A **key certificate** is `{"body": {...}, "root_key_id": "...", "sig": "..."}`. The body has exactly
`type` (`"key_cert"`), `app_id`, `environment`, `key_id`, `public_key`, `roles` (`signer`/`approver`),
`serial`, `not_before`, `not_after` (UTC, `YYYY-MM-DDTHH:MM:SSZ`). The root signs
`"flutter-ota-system/key-certificate/v1\n" + canonical(body)`.

An **approval** is `{"cert": <approver certificate>, "sig": ...}` over
`"flutter-ota-system/patch-approval/v1\n" + manifest bytes`. If approvals are present, the server
checks each one. How many approvals are *required* is decided by the app build, not the server.

A **revocation list** is an `OTAPRT02` container with an **empty module**. Its "manifest" is
`{"type":"revocations","release_id":..., "sequence":N, "revoked_patch_ids":[...],
"revoked_key_ids":[...], "revoked_cert_serials":[...] (optional)}`, signed by a root key over
`"flutter-ota-system/revocations/v1\n" + body`. The signature block is `{alg, key_id, sig}` only.

Public keys are base64 **uncompressed P-256 points** (65 bytes, starting with `0x04`).

## 4. Admin endpoints (all need `X-API-Key`)

`{app}` is the application id (UUID) **or** its slug.

| Method and path | What it does |
| --- | --- |
| `GET /v1/admin/apps/{app}/trust` | Lists roots, certificates and revocation lists of the app |
| `POST /v1/admin/apps/{app}/trust/roots` | Registers a root public key. JSON `{"key_id", "public_key"}`. 201 new, 200 same key again, 409 same id with another key |
| `POST /v1/admin/apps/{app}/trust/roots/{key_id}/revoke` | Stops trusting a root on the server (new certificates, lists and patches under it are refused). Phones keep the roots compiled into their build |
| `POST /v1/admin/apps/{app}/trust/certificates` | Uploads a root-signed key certificate (JSON body = the certificate). The server checks it and stores it; it never creates certificates. 409 `duplicate_serial` if the serial is taken by a different certificate |
| `POST /v1/admin/apps/{app}/trust/revocations` | Uploads a root-signed revocation list (multipart `file`, max 256 KiB). Its `sequence` must be higher than every earlier list of this app (`stale_sequence`, 409). `release_id` must be a release of this app. Stored byte for byte |

Releases and patches use the existing routes:

| Method and path | Phase 4 additions |
| --- | --- |
| `POST /v1/admin/apps/{slug}/releases` | Optional `id` (UUID), `toolchain_id`, `dart_revision`, `bytecode_format`, `interface_sha256`, `trust_environment` (default `production`). When set, `dbc-v1` uploads must match them |
| `POST /v1/admin/releases/{id}/patches` | `artifact_format: "dbc-v1"` (Android releases only) |
| `POST /v1/admin/patches/{id}/artifacts` | For a `dbc-v1` patch: multipart `arch` + `file` (the container). Verified, then stored unchanged |

### What the server checks on a `dbc-v1` upload

1. Size, magic, lengths, and no trailing data.
2. Manifest is canonical JSON and follows the v2 schema; the toolchain `id` matches its fields.
3. `app_id`, `release_id`, `baseline_libapp_sha256` match the server (see the table above).
4. The release's baseline identity, if set: toolchain id, Dart revision, bytecode format,
   host interface SHA-256.
5. The signature block has a certificate. The certificate was signed by a registered,
   non-revoked root of this app, is for this app, has the `signer` role, is for the release's
   environment, is valid now, and neither its serial nor its key id is revoked.
6. The manifest signature verifies with the certified key; approvals (if any) verify.
7. Module size and SHA-256 match the manifest.
8. `patch_id` is not revoked and was not uploaded before (`duplicate_patch_id`, 409). All
   architectures of one server patch may share one `patch_id`.
9. `sequence` grows with the patch number: higher than every older patch of the release and
   lower than every newer one (`replay`, 409). All architectures of one patch use the same
   sequence.
10. `expires_at`, if present, is in the future.
11. If a certificate with the same serial was uploaded earlier, it must be the same certificate
    (`cert_conflict`, 409).

"Revoked" means listed in **any** stored revocation list of the app.

Errors use the existing style: `{"detail": "<code>: <reason>"}`. Codes are the same names the
phone's verifier uses (`bad_signature`, `untrusted_root`, `wrong_baseline`, `revoked_key`, ...).
Status 413 for `too_large`, 409 for the conflicts above, 422 for everything else.

Stored artifact: `payload_sha256` and `size_bytes` describe the **whole container**,
`base_artifact_sha256` is the baseline `libapp.so`, `result_sha256` is the module SHA-256,
`signature` and `key_id` are `null`. New fields: `manifest_patch_id`, `sequence`,
`signer_key_id`, `cert_serial`, `expires_at`.

## 5. Device endpoints

### `POST /v1/devices/register`

Send **either** `app` (slug, as before) **or** `application_id` (UUID, new). If both are sent they
must name the same app (otherwise 422). The same `installation_id` maps to the same device either way.

### `GET /v1/updates/check`

Unchanged for every client that does **not** put `dbc-v1` in `supported_formats`: the response is
byte for byte the same as before (new fields are left out of the JSON, not sent as `null`).

When `supported_formats` contains `dbc-v1`:

- A `dbc-v1` patch can be offered. Its `patch` object has the usual fields, with
  `signature: null` and `key_id: null`, plus:
  - `download_url`, `size_bytes`: the container file;
  - `sha256`: SHA-256 of the whole container (same as `payload_sha256`);
  - `patch_id`, `sequence`: copied from the signed manifest;
  - `expires_at` (only if the manifest has one).
- Patches that are expired, or whose `patch_id`, signer key or certificate serial is revoked, are
  not offered.
- `revocations` (only if a list exists for the device's release):
  `{"sequence": N, "release_id": "...", "data_base64": "<the signed list, byte for byte>"}`.
  The phone verifies it with its compiled-in root keys and ignores a list whose sequence is not
  higher than the one it already has.

Certificates are not sent separately: each patch carries its own certificate in its signature block.

The phone must still verify everything itself. The server's checks only stop bad uploads early.

## 6. Database (migration `0004`)

- New tables: `trust_roots`, `key_certificates` (serial unique per app),
  `revocation_lists` (sequence unique per app, raw bytes, `release_id` nullable; deleting a
  release keeps its lists and clears the link).
- `releases`: `toolchain_id`, `dart_revision`, `bytecode_format`, `interface_sha256`,
  `trust_environment` (all nullable).
- `patch_artifacts`: `signature` and `key_id` become nullable; new `manifest`,
  `manifest_sha256`, `manifest_patch_id` (indexed), `sequence`, `signer_key_id`, `cert_serial`,
  `expires_at` (all nullable).
- Downgrade removes all of that. `dbc-v1` artifacts get an empty `signature`/`key_id` so the old
  NOT NULL columns can come back; old clients never ask for `dbc-v1`, so nothing serves them.

## 7. Known limits

- The server still loads its own signing key at startup, for the older formats.
- Public store apps: the AOT policy approval (ADR-0011) is not required for `dbc-v1` yet.
- Revocation sequences are counted per app, not per release.
- Tested with SQLite in the test suite; the migration has not been run against Postgres yet.
