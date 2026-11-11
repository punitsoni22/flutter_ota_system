# Security

> **Alpha disclaimer.** Flutter OTA System v0.1.0-alpha.1 has **not** undergone an independent security audit.
> This page describes the security model as implemented, and its known gaps. It does not certify
> that the implementation is free of flaws. Validate it yourself before users depend on it. Report
> vulnerabilities privately as described in [SECURITY.md](../SECURITY.md).

## What is being protected

Flutter OTA System delivers files that installed apps load: configuration (`mock-v1`) or **compiled Dart code**
(Android code patches). Anyone who can make a device accept a patch can change what the app does
for every user in that rollout. That is the main risk, and most controls below exist to stop it.

## Controls at a glance

| Control | Status | Where |
|---|---|---|
| ES256 signature over all patch metadata, verified on the device | ✅ Implemented | `signing.py`, `canonical.py`, `signature.dart` |
| SHA-256 and exact-size checks on download | ✅ Implemented | `ota_client.dart` |
| Base + result hash checks for code patches; re-check before loading | ✅ Implemented | `aot_runtime.dart`, `OtaBoot.java` |
| Anti-replay (no downgrade without a server rollback) | ✅ Implemented | client `state.dart`, server `updates.py` |
| Compatibility binding (app, release, platform, arch, format in the signature) | ✅ Implemented | `canonical.py` |
| Device tokens (HS256 JWT, per device) | ✅ Implemented | `auth.py` |
| Admin authentication | 🟡 One shared API key | `auth.py` |
| Private storage for store builds | ✅ Implemented | `storage.py`, nginx/Caddy config |
| Production startup safety checks | ✅ Implemented | `config.py` |
| Store-policy gate for public-store code patches | ✅ Implemented | `routers/admin.py` |
| Secret scanning in CI (gitleaks) | ✅ Implemented | `.github/workflows/ci.yml` |
| **RBAC**, users, SSO, MFA | 🔭 Planned | [roadmap Phase 8](roadmap/phase-08-admin-rbac.md) |
| **Audit log** | 🔭 Planned | Phase 8 |
| **Azure Key Vault / KMS / HSM signer** | 🔭 Planned | [roadmap Phase 6.4](roadmap/phase-06-signing.md#64-key-vault-signer) |
| **Short-lived signed download URLs** | 🔭 Planned | ADR-0008 (not written) |
| Rate limiting on device endpoints | 🔭 Planned | [roadmap Phase 3.7](roadmap/phase-03-device-control-plane.md#37-rate-limiting-basic) |
| Individual device-token revocation | ❌ Not available | — |
| TLS | Your responsibility (the single-server compose uses Caddy) | `deploy/` |

## Device authentication

- A device registers with `POST /v1/devices/register` and gets an **HS256 JWT** signed with
  `OTA_DEVICE_JWT_SECRET`. Claims: device id, application id, installation id, `typ: device`,
  issue and expiry time (30 days by default, `OTA_DEVICE_TOKEN_TTL_SECONDS`).
- The token is required for `/v1/updates/check` and `/v1/events/batch`, and scopes them to its
  own application.
- **Registration is open**: anyone who knows the app slug can register any installation id. The
  token limits what a caller can see; it does not prove the caller is a genuine install.
- Tokens cannot be revoked one by one. Rotating `OTA_DEVICE_JWT_SECRET` invalidates all of them;
  `ota_client` re-registers automatically.
- On the device the token is stored in the client's state file in the app's private folder, not
  in a hardware-backed keystore.

## Admin authentication and RBAC

- All of `/v1/admin` requires the header `X-API-Key`, compared in constant time with
  `OTA_ADMIN_API_KEY`. The CLI, CI and the `/admin` page all use this one key.
- **There is no RBAC**: no users, roles, per-person keys, SSO or MFA. Whoever has the key can
  publish code to every device.
- Until roles exist: keep the key in a password manager, share it with as few people as possible,
  rotate it when someone leaves, and restrict `/v1/admin` and `/admin` at the network level
  (VPN, IP allow-list, or a reverse proxy with SSO).
- The `/admin` page holds no secrets; it sends the key you type to the API.

## What is signed

When a patch file is uploaded, the server computes its SHA-256 itself and signs a **canonical
message** ([ADR-0002](adr/0002-signature-scheme.md)):

```
"OTA-PATCH-V1\n" + length-prefixed(
    protocol_version, application_id, release_id, patch_number, platform, arch,
    runtime_abi, artifact_format, base_artifact_sha256, payload_sha256, result_sha256, size_bytes)
```

Each field is UTF-8 with a 4-byte big-endian length prefix, so fields cannot be shifted into
each other. The signature is ECDSA P-256 / SHA-256 (ES256), encoded as raw `r‖s` (64 bytes),
base64. The device rebuilds the message from the update-check response **and its own** platform
and arch, so no field can be swapped without breaking the signature. Python
([`canonical.py`](../backend/app/canonical.py)) and Dart
([`canonical.dart`](../packages/ota_client/lib/src/canonical.dart)) share a test vector.

**Not signed:** the rollback/revocation lists, `download_url` and `next_check_after_seconds`.
Without TLS, a network attacker could fake "your patch is revoked" (a denial of service, not code
execution). Use HTTPS.

## Device-side checks

In order, before a patch can run ([`ota_client.dart`](../packages/ota_client/lib/src/ota_client.dart)):

1. Not a patch that already failed on this device.
2. **Anti-replay:** the patch number must be higher than the highest number this install ever
   accepted, unless the server names it as the rollback target.
3. `arch`, `runtime_abi` and `artifact_format` match this app and runtime.
4. `key_id` is one of the keys compiled into the app.
5. **ES256 signature verifies** over the canonical message. This happens **before** the download.
6. Download stops if more than `size_bytes` arrive; the final size must match exactly.
7. **SHA-256** of the file equals `payload_sha256`.
8. Code patches: the store `libapp.so` must match `base_artifact_sha256` (the patch was built for
   this exact build), and the rebuilt file must match `result_sha256`.
9. Before use: `mock-v1` payloads are re-hashed on every start; `OtaBoot` re-checks the size and
   SHA-256 of a patched `libapp.so` before loading it (hashed once per file, then cached).

Also, before any of these:

- **Patch id:** must be a canonical lowercase UUID, because the client uses it as a directory
  name and it is **not signed** (see below). Any other id is refused before downloading; a state
  file or native `boot.json` entry with another id is discarded. Dart (`patch_id.dart`) and
  Android (`OtaPaths.java`) use the same pattern; a test compares them.
- **URLs:** release and profile builds use `https://` only, for the server, patch downloads and
  every redirect. Debug builds may also use `http://localhost`/`127.0.0.1`/`[::1]` and
  `http://10.0.2.2` (emulator). The client follows redirects itself (GET only, at most 5),
  checks every destination, never follows `https://` → `http://`, and drops the device token
  when a redirect changes the host.
- **Timeouts:** connect 15 s; API calls 15 s; patch download: response 30 s, stall 30 s, total
  10 min.

### Protocol v2 requirement: sign the patch id

In protocol v1 (`OTA-PATCH-V1`, [ADR-0002](adr/0002-signature-scheme.md)) the signed message
covers the app, release, patch number, platform, arch, runtime ABI, format, hashes and size, but
**not the patch id** and not the download URL. The client therefore treats both as untrusted
input (strict UUID check, URL rules above). Protocol v2 must add `patch_id` to the signed
message. That changes every signature and the ADR test vector, so it needs a new protocol
version that old clients ignore, and is not part of v1.

### Download hosts

Downloads are **not** restricted to the API's host: patch files are normally served from another
host (`OTA_CDN_BASE_URL`: nginx/Caddy, a CDN, or an S3-compatible public bucket such as Supabase
Storage, Cloudflare R2 or AWS S3). Integrity comes from the signature and SHA-256, not from the
host. An optional allow-list of download hosts in the client is a possible later addition.

[`scripts/verify_demo.sh`](../scripts/verify_demo.sh) re-implements the canonical message
independently and confirms that a corrupted file, flipped signature bits, a changed patch number,
a substituted hash and a different key are all rejected.

## Patch compatibility checks

| Layer | Check |
|---|---|
| Server | Patch must belong to the device's release; artifact must exist for its arch; format must be supported |
| Signature | App, release, patch number, platform, arch, runtime ABI and format are inside the signed message |
| Device | Base hash must match the installed store code (code patches) |
| CLI (build time) | Same Flutter version as the release; no native, Java/Kotlin, manifest, resource or asset changes |

## Key management

### Local development

`./flutter-ota-system.sh setup` (through `./scripts/generate_dev_signing_key.sh`) creates the key once inside
the Docker volume `flutter-ota-system_keys` (key id `local-dev-1`, file mode 600, owned by the API's non-root
user). It never touches the working tree or the image, and restarts never replace it;
`./flutter-ota-system.sh reset` (or `cleanup_local.sh`) deletes it. `./flutter-ota-system.sh backup` copies it, together
with `.env`, into `backups/` (git-ignored): keep those folders private.
`OTA_AUTO_GENERATE_SIGNING_KEY=false` stops the API from creating keys silently. `setup` also
writes random local values for the admin key and server secrets into a new `.env`; they are still
development values. **Never ship an app that trusts a development key.**

### Production (what exists today)

The private key is a **local PEM file or an environment variable**, held in the API process
memory. Recommended handling:

1. Generate the key once, offline: `python -m app.keygen --pem` prints a one-line
   `OTA_SIGNING_KEY_PEM` and the public key. Or run `python -m app.keygen` on the server to write
   the key file (0600).
2. Store it in a secret manager; keep an encrypted offline backup. `deploy/backup.sh` also copies
   the key file, so protect those backups.
3. Set `OTA_ENV=production` and `OTA_AUTO_GENERATE_SIGNING_KEY=false`.
4. Limit who can read the secret and who can deploy the API.

### Trusted keys in apps and rotation

Apps embed a **set** `{key_id: public_key}`. Only those key ids are trusted, and a patch with an
unknown `key_id` is refused before download. Rotating the key therefore needs **new store
builds**. Prepare for it: ship builds that trust both the current key and a pre-generated backup
key. There is no server-side rotation tooling yet, and the server signs with one key at a time.

### Azure Key Vault (planned, not implemented)

The planned design: an EC P-256 key in Key Vault (Premium / Managed HSM) with only the `sign`
permission, used through a managed identity. A `KeyVaultSigner` would implement the existing
`Signer` interface in [`signing.py`](../backend/app/signing.py): `sign()` sends the SHA-256 digest
to Key Vault and converts the result to raw `r‖s`; `public_key()` reads the public key. The
private key would never leave the HSM. **None of this exists yet.**

## Artifact downloads

- Patch URLs are **public and permanent** (`/cdn/patches/<sha256>`), so CDNs can cache them.
  Integrity comes from the signature, not from a secret URL. **Never put secrets in a patch.**
- **Short-lived signed URLs (S3 pre-signed, Azure SAS) are not implemented**, so there is no URL
  expiry.
- Store builds (`releases/`, the app's full compiled code) are private: only the admin API serves
  them. nginx and Caddy return 404 for any other `/cdn/` path.
- Use HTTPS for the API and file server in production; the production startup check requires an
  `https://` CDN URL.

## Replay protection, rollback and revocation

- **Anti-replay:** see device-side check 2. A patch that crashed does not raise the highest
  accepted number, so it cannot block older good patches.
- **Rollback** marks a patch `rolled_back`; devices move to the newest other eligible patch or the
  store code. It can be published again.
- **Revoke** is permanent. Every update-check response lists revoked numbers, and clients drop
  those patches even if they are already downloaded.
- Both reach a device only when the app **calls `checkForUpdate()`** (the client has no timer)
  and take effect on the next start. Offline devices keep running their last good code.

## Audit logging

**Not implemented.** Who created, published, rolled back or revoked a patch, and when, is not
recorded. Patches keep their creation time only. Exceptions: policy approvals are stored with
their reason and time (`ota app policy-history`, [KI-2](known-issues.md#ki-2-the-policy-approval-reason-is-not-stored)), and
promotion-check overrides are written to the server log with their reason. Neither records *who*
did it, because there is only one shared admin key. Until an audit log exists: keep
reverse-proxy access logs for `/v1/admin`, restrict admin access, and
track releases in your own change management.

## Threat model

| Threat | Mitigation today | Residual risk |
|---|---|---|
| Patch modified in transit or on the file server | SHA-256 + ES256 signature, verified on device with compiled-in keys | None for integrity while the key is safe. Use HTTPS for the rest |
| Fake update-check response | Signature covers every field that defines the patch | Unsigned lists can be spoofed without TLS (denial of service) |
| Replay of an old, valid but buggy patch | Highest-accepted number on device; server never offers older patches unless the current one is bad | Downgrade only through an authenticated rollback over TLS |
| Patch for another app / release / arch | Those values are signed | — |
| **Stolen signing key** | None automatic | **Critical.** See the procedure below |
| **Stolen admin API key** | Constant-time check; production refuses default or short keys | **Critical.** The attacker can publish patches that the server signs. No RBAC, MFA or audit log |
| Stolen device token | Scoped to one device and app; read-only metadata + counters | Valid up to 30 days; no per-token revocation |
| Fake devices, scraping | Registration needs a known slug | Open registration, no rate limiting; patch files public by hash |
| Broken patch | Boot protection + server rollback/revoke | Crashes after confirmation, or before the native hook, are not covered |
| Malicious insider | — | No approvals, no two-person rule, no audit log |
| Store-policy violation | `aot_policy_approved` gate for `public_store` apps | The policy decision is the operator's |
| Supply chain (dependencies, CI) | gitleaks, licence gate, read-only CI token | GitHub Actions are pinned to tags, not commit SHAs; no dependency vulnerability scan in CI |

## Compromised signing key: procedure

1. **Contain:** stop the API or cut admin network access. Revoke every patch you did not publish
   (`ota patch revoke`).
2. **Assess:** with the key, an attacker can sign patches. Devices accept them only if the
   attacker also controls the update-check response (your server, DNS or TLS). Check those.
3. **Rotate:** create a new key with a new `key_id`, configure the server, and ship **new store
   builds** that trust only the new key (and a new backup key).
4. **Retire:** once old builds are gone, delete their releases so they get no more patches.
5. **Disclose** as your obligations require.

## Secret rotation

| Secret | Effect of rotating |
|---|---|
| `OTA_ADMIN_API_KEY` | CLI, CI and admin users need the new key. No device impact |
| `OTA_DEVICE_JWT_SECRET` | All device tokens become invalid; clients re-register on HTTP 401 |
| `OTA_ROLLOUT_HMAC_SECRET` | Every rollout group reshuffles. Do it only when no partial rollout is running |
| Database password, S3 keys | Update the server environment and restart |
| Signing key | Needs new store builds (above) |

## Security limitations (summary)

No independent security audit, no RBAC, no audit log, no HSM/KMS, no signed URLs, no rate limiting, open device
registration, one signing key at a time, device token stored without hardware protection, and no
iOS support (iOS is not tested). See [limitations.md](limitations.md).

## Secrets in this repository

No secrets are committed. `.env`, key files and local state are git-ignored. CI runs gitleaks on
every pull request and push. `.env.example` contains only clearly fake values, and the production
startup checks reject them.
