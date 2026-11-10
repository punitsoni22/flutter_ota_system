# Punit security model

> **Alpha disclaimer.** Punit v0.1.0-alpha has not undergone an independent security audit. This
> document describes the intended model and its known gaps. It does not certify that the
> implementation is free of flaws. Validate it yourself before using Punit for anything users
> depend on. Report vulnerabilities as described in [SECURITY.md](../SECURITY.md).

## What is being protected

Punit delivers files that installed apps load: configuration for `mock-v1`, or **compiled Dart
code** for Android code patches. An attacker who can make a device accept a patch can change what
the app does for every user in the targeted rollout. That is the main risk.

## Threat model (summary)

| Threat | Mitigation in v0.1.0-alpha | Residual risk / gap |
|---|---|---|
| Network attacker modifies a patch in transit or on the CDN | SHA-256 check + ES256 signature over all metadata, verified on device with a key compiled into the app | None for integrity, as long as the key is safe. Still use HTTPS for confidentiality and metadata integrity |
| Attacker replaces the update-check response | Signature covers app, release, patch number, platform, arch, format, all hashes and size | Unsigned fields (e.g. rollback lists) can be spoofed without TLS: use HTTPS |
| Replay of an old, valid but buggy patch | Client keeps the highest accepted number and refuses lower ones. Server never offers older patches unless the current one is bad | Downgrade to an older patch happens only via an authenticated rollback decision over TLS |
| Patch for another app / release / arch | Those ids are inside the signed message | — |
| Stolen **signing key** | None automatic | **Critical.** The attacker can sign patches. See "Compromised signing key" |
| Stolen **admin API key** | Constant-time comparison; production startup refuses default/short keys | **Critical.** The attacker can publish patches the server signs. No RBAC, MFA or audit log yet |
| Stolen device token | Token is scoped to one device/app; it only reads update metadata and posts counters | Tokens last 30 days and can't be revoked individually |
| Fake devices / scraping | Registration requires a known app slug | Registration is open with no rate limiting. Patch files are public by hash. **Never put secrets in patches** |
| Broken patch bricks the app | Boot protection: an unconfirmed start falls back to the last good code. Server rollback/revoke | Crashes before the native boot hook or after confirmation are not covered |
| Malicious insider with admin access | Not addressed | No approvals, no two-person rule, no audit log |
| Store-policy violation | `aot_policy_approved` gate for public-store apps | Legal/policy review is the operator's job ([code-push.md](code-push.md)) |

## Signing trust model

- One ES256 (P-256) private key signs every patch artifact when it is uploaded. The server signs
  only canonical metadata that it computes itself, including the SHA-256 of the bytes it stored.
- Apps ship with an allow-list `{key_id: public_key}` (`OTA_PUBLIC_KEY` at build time). A
  patch with an unknown `key_id` is rejected before download.
- Rotating the key therefore requires **new store builds** that trust the new key. Plan for it:
  ship builds that trust both the current key and a pre-generated backup key. Multi-key trust is
  supported by `ota_client` (a map of keys), but there is no server-side rotation tooling yet.

## Integrity checks on the device

In order: size limit during download, exact size, SHA-256 of payload, known `key_id`, ES256
signature over the canonical message, anti-replay. Code patches also check that the base hash
matches the installed store code and that the rebuilt result hash matches. The payload hash is
re-checked from disk before each use.

`scripts/verify_demo.sh` re-implements the canonical message independently. It proves that
signatures verify and that a corrupted file, flipped signature bits, a changed patch number, a
substituted hash or a different key are all rejected.

## Private-key handling

**Local development:** `./scripts/generate_dev_signing_key.sh` creates the key inside the Docker
volume `punit_keys`. It never touches the working tree, and `cleanup_local.sh` deletes it.
`OTA_AUTO_GENERATE_SIGNING_KEY=false` stops the API from creating keys silently. The dev key id
is `local-dev-1`. **Never ship an app that trusts a dev key.**

**Production (current options, in order of preference):**

1. Generate the key **once**, offline (`python -m app.keygen --pem`), and store it in a secret
   manager. Inject it as `OTA_SIGNING_KEY_PEM`, or as a 0600 file readable only by the API
   user. Keep an encrypted offline backup.
2. Set `OTA_ENV=production` and `OTA_AUTO_GENERATE_SIGNING_KEY=false`.
3. Restrict who can read the secret and who can deploy the API.

**Azure Key Vault (recommended target, not implemented):** use a Key Vault (Premium/Managed HSM)
EC P-256 key with `sign` permission only, accessed via managed identity. Implement a
`KeyVaultSigner` with the existing `Signer` interface: `sign(message)` sends the SHA-256 digest
to Key Vault `ES256` sign and converts the result to raw `r||s`; `public_key()` reads the public
JWK. The private key never leaves the HSM. This is on the roadmap. Until then the key exists in
process memory on the API host.

## Artifact URLs

Patch URLs are public and permanent (content-addressed), so CDNs can cache them. Integrity
comes from the signature, not from secret URLs. Short-lived signed URLs (S3 pre-signed / Azure
SAS) are **not implemented**. Add them if your patches must not be downloadable by third
parties, and never treat patch contents as confidential. Store builds (`releases/`) are private
and served only through the admin API.

## Authentication separation

| Caller | Credential | Scope |
|---|---|---|
| Device | HS256 JWT from `/v1/devices/register` (`OTA_DEVICE_JWT_SECRET`) | `/v1/updates/check`, `/v1/events/batch`, own app only |
| Admin / CI / CLI | `X-API-Key` (`OTA_ADMIN_API_KEY`) | Everything under `/v1/admin`, plus `/admin` page actions |

The secrets are independent, and a device token can never call admin endpoints. In production,
also restrict `/v1/admin` and `/admin` at the network layer (VPN, IP allow-list or a reverse
proxy with SSO), because a single shared key is weak.

## Rollback, revocation, anti-rollback

- **Rollback:** devices on the patch move to the newest other eligible patch or the store build
  on their next check. The patch can be re-published.
- **Revoke:** permanent. Every response lists revoked numbers, and clients refuse them even if
  cached.
- **Anti-rollback:** the client stores the highest accepted patch number and refuses
  lower-numbered offers, except when the server marks the current patch bad. A crashed patch
  does not raise that number.
- Revocation reaches a device only when it checks in (default every 30 minutes with jitter).
  Offline devices keep running the last good patch.

## Audit logging

**Not implemented.** Patch, rollout and key actions are not recorded with who/when. Until it is:
keep reverse-proxy access logs for `/v1/admin`, restrict admin access, and record releases in
your change management. An audit log is on the roadmap.

## Compromised signing key procedure

1. **Contain:** stop the API, or remove admin network access. Revoke every patch you did not
   publish (`ota patch revoke`). Revoke only works for patches the server knows about.
2. **Assess:** an attacker with the key can sign patches and serve them from any server the app
   talks to. Devices accept them only if the attacker also controls the update-check response
   (your server, DNS, or TLS). Check for those too.
3. **Rotate:** generate a new key (new `key_id`) and configure the server with it. Ship **new
   store builds** that trust only the new key (and a new backup key).
4. **Retire:** once old builds have aged out, stop serving them patches (no release record →
   no updates).
5. **Disclose** to affected users/customers as your obligations require.

Being able to recover faster depends on preparation: builds that already trust a backup key let
you switch without waiting for a store review.

## Secret rotation

| Secret | Effect of rotating |
|---|---|
| `OTA_ADMIN_API_KEY` | CLI/CI/admin users need the new key. No device impact |
| `OTA_DEVICE_JWT_SECRET` | All device tokens become invalid. `ota_client` re-registers automatically on HTTP 401 |
| `OTA_ROLLOUT_HMAC_SECRET` | Rollout cohorts reshuffle. Do it only when no partial rollout is running |
| Database password, S3 keys | Update the server env and restart |
| Signing key | Requires new store builds (see above) |

## Secrets in this repository

No secrets are committed. `.env`, key files and local state are git-ignored. CI runs gitleaks on
every pull request. `.env.example` contains only clearly fake values, and the production
startup checks reject them.

## Disclosure

See [SECURITY.md](../SECURITY.md). Do not report vulnerabilities in public issues.
