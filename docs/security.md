# Security

> [!WARNING]
> **No independent security audit.** This page describes the security model as implemented, and its known gaps. It does not certify that the implementation is free of flaws. Validate it yourself before users depend on it. Report vulnerabilities privately as described in [SECURITY.md](../SECURITY.md).

**What is being protected.** Flutter OTA System delivers code that installed apps run. Anyone who can make a device accept a patch can change what the app does for every user in the rollout. Most controls below exist to stop that.

There are two patch paths, with different trust models:

| | Bytecode architecture (`dbc-v1`, unreleased, experimental) | Original alpha (`v0.1.0-alpha.1`) |
| --- | --- | --- |
| Who signs | **The developer**, on their own machine | The **server**, with one server-held key |
| Server holds a private signing key | **No** | Yes |
| Key hierarchy | Offline root key → certified signer keys; rotation and revocation | One key; no rotation tooling |
| Code runs as | Dart bytecode in the custom engine's interpreter, verified first | A replaced compiled `libapp.so` |

## Developer-owned signing

### The keys

```text
app ROOT key (offline; its public key is compiled into your store build)
  └── signs a CERTIFICATE: app id, environment, role "signer", serial, validity
        └── your SIGNER key signs each patch, on your machine (or in your own CI)
```

`flutter_ota keys init` creates them under `~/.config/flutter_ota/keys/<app_id>/`:
- `roots/<key_id>.key` and `signers/<key_id>.key` are the **private** keys, mode 0600.
- `.pub` files and `signers/<key_id>.cert.json` are public.

**Rules for the private keys:**
- Only the **public** root key and the certificate are sent to your server.
- Private keys never go into your project, your APK/AAB, the build configuration or the server.
- Never commit them, and never paste them into a chat, a ticket or a log.
- Keep the root key offline when you can. It is only needed to certify new signer keys and to sign revocation lists.

### What is signed

A patch is one `OTAPRT02` file:
- a canonical-JSON **manifest**;
- a signature block;
- the Dart bytecode module.

**The signature:**
- ES256 (ECDSA P-256 + SHA-256), raw `r‖s`;
- computed over `"flutter-ota-system/patch-manifest/v2\n"` plus the manifest. The prefix means a patch signature can never be reused as another kind of signature.

**What the manifest binds the patch to:**
- the app id;
- the store release id and the SHA-256 of that release's `libapp.so`;
- a unique patch id and a sequence number (replay protection);
- the runtime (engine and Dart revisions);
- the toolchain id (content hash);
- the host interface hash;
- the module's SHA-256 and size;
- an optional expiry.

### Who checks it

**The CLI**, before upload:
- the manifest schema;
- the signer certificate: app, environment, `signer` role, validity, a root compiled into the release, and the key file mode;
- it re-verifies its own signature.

**The server**, on upload (`dbc.py`):
- the binding to app, release and baseline `libapp.so` hash;
- the certificate chain to a registered, non-revoked root;
- the signature and any approvals;
- the module hash and size;
- that the patch id is unique and the sequence number is higher;
- the expiry.

It stores the file unchanged and **never signs it**.

**The phone**, before activation and again at **every start**:
- the same checks, against the **root keys compiled into the store build**;
- the signed revocation list;
- replay, by sequence number.

### Rotation, revocation and recovery

| Situation | What to do |
| --- | --- |
| **Planned rotation** of a signer key | Certify a new signer key with the root key. It works at once; no new store release |
| **Signer key stolen** | Sign a revocation list with the root key that revokes the certificate serial (and key id), certify a new signer key, and re-sign the current patch. A stolen signer key cannot certify keys and cannot revoke anything |
| **Root key lost or stolen** | Needs a **new store release** with a new root key. Keep the root key offline and backed up |
| **Bad patch** | `flutter_ota rollback` (reversible) or `ota patch revoke` (permanent) |

Revocation lists are signed by a root key and have a sequence number; an older list is refused. The server stores them, and phones fetch them with the update check.

**Approvals** (extra approver signatures) are supported by the verifier, but only tested on Linux. The CLI does not add them yet.

## Code safety on the phone

A correctly signed patch can still contain broken code. More layers protect the app:

1. **Build time (`patch_guard`).** Before compiling, it rejects:
   - FFI, `dart:mirrors` and internal `dart:_` libraries;
   - dynamic calls and `noSuchMethod`;
   - compile errors;
   - dependencies that are not part of the store build.
2. **Reference verifier (`bc_verify`).** It runs on every module before signing.
3. **In-VM bytecode verifier.** It is part of the custom engine, and checks every function while the module is read, before any of its code runs:
   - opcodes and instruction boundaries;
   - registers, branch targets and object-pool types;
   - argument counts, field offsets and stack depth.

   Interpreter runtime guards also protect memory-indexing instructions. See [architecture/bytecode-verifier.md](architecture/bytecode-verifier.md).
4. **Separate verification process.** A new patch is first loaded in `:flutter_ota_verify`. If that process refuses the patch or crashes, the patch is never activated, and the app keeps running.
5. **Activation at the next start.** Running code is never swapped live.
6. **Crash recovery.** A patch that crashes the app twice is rolled back and blocklisted. Android exit information tells real crashes apart from force-stops and OS kills.

## Server, admin and device security

- **Admin API:**
  - every `/v1/admin` route needs `X-API-Key`, compared in constant time;
  - there is **one shared key**, with no users, roles (RBAC), MFA or audit log. Whoever has it can publish patches to every device;
  - restrict admin access at the network level (VPN, IP allow-list or SSO proxy).
- **Devices:**
  - devices register (by app UUID or slug) and get a 30-day **HS256 JWT** for the update check and events;
  - registration is open: a token limits what a caller sees, it does not prove the install is genuine;
  - tokens cannot be revoked one by one.
- **Transport:**
  - release builds use `https://` only;
  - the bytecode runtime also allows `http://` to loopback addresses, for local testing;
  - use HTTPS in production. Production start-up checks refuse unsafe settings.
- **Downloads:**
  - patch URLs are public and permanent (`/cdn/patches/<sha256>`); integrity comes from signatures, not secret URLs;
  - **never put secrets in a patch.**
- **Store builds:** they are not uploaded in the bytecode architecture, only their `libapp.so` hash. In the original alpha, they are stored privately.

## Original alpha: server-held key

In `v0.1.0-alpha.1`, the **server** signs every patch, with one EC P-256 key (`OTA_SIGNING_KEY_PEM` or `OTA_SIGNING_KEY_PATH`) for all apps. Apps trust the public keys compiled into them (`ota key show --dart`).

**Consequences:**
- The server, the signing key and the admin API key are **equally sensitive**. Whoever controls them can sign patches that devices accept.
- There is no rotation tooling. Replacing the key needs new store builds that trust the new key. Ship builds that already trust a backup key.
- The patch id and the rollback/revocation lists are not signed (protocol v1). Clients treat them as untrusted input.

**If that key is compromised:**
1. Stop the API, or cut admin access.
2. Revoke every patch you did not publish.
3. Check the server, DNS and TLS.
4. Create a new key, and ship new store builds that trust only it.

Local development keys (`local-dev-1`) must never be trusted by a shipped app.

## Known security limitations

- **No independent security audit, no penetration test.**
- **Not a sandbox.** The verification process runs with the **same Linux user** as the app: Android isolated processes cannot run Flutter in release builds.
- **Some malformed patches are contained, not rejected cleanly.** About 40 test files with corrupt headers or sections abort the separate verification process: the reader stops before function verification. The app stays alive and the patch is not used, but this is containment, not a clean rejection.
- **The bytecode verifier is not a type checker.** Type confusion into VM runtime entries remains a residual risk, reduced by the runtime guards, the signature and the separate process.
- **The toolchain id is declared by the signer.** It is not proven. A stolen signer key can declare any toolchain; reproducible builds allow audits.
- **Admin access is coarse:** one shared key, no RBAC, no audit log, no KMS/HSM signer, no rate limiting, no short-lived download URLs.
- **The device token is not hardware-protected.** It is stored in the app's private storage.

## Secret rotation (server)

| Secret | Effect of rotating |
| --- | --- |
| `OTA_ADMIN_API_KEY` | CLI, CI and admin users need the new key. No device impact |
| `OTA_DEVICE_JWT_SECRET` | All device tokens become invalid; clients register again |
| `OTA_ROLLOUT_HMAC_SECRET` | Rollout groups reshuffle. Do it only when no partial rollout is running |
| Original alpha signing key | Needs new store builds |

No secrets are committed to this repository. `.env`, key files and local state are git-ignored, and CI runs gitleaks.

Related: [privacy and data handling](privacy-and-data-handling.md) · [limitations](limitations.md) · [Google Play](policy/google-play.md) · [Apple App Store](policy/apple-app-store.md).
