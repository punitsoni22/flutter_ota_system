# Signing keys and the trust model

How patches are signed and verified in Flutter OTA System v0.1.0-alpha.1, what that protects,
where it stops, and what the operator must do. Every statement links to the code that implements
it. Planned work is marked as such.

> [!IMPORTANT]
> Flutter OTA System has **not** been independently security-audited. External sources on this
> page were checked on **2026-11-12**.

## The trust model in one picture

```
 admin (shared X-API-Key) ──upload patch──▶ server ── signs with the PRIVATE key (ES256) ──▶ database
                                              │
 device ◀── update-check response (signed fields + signature, unsigned id/URL/rollback info) ──┘
   │  verifies ES256 with PUBLIC keys compiled into the app, BEFORE downloading
   │  downloads, checks size + SHA-256; code patches: rebuilds libapp.so, checks base + result SHA-256
   ▼
 next start: OtaBoot.java checks the file's path, size and SHA-256 recorded in boot.json, then loads it
```

The device trusts **whatever the server's key signs**. The server signs **whatever an admin
uploads**. So the private key, the server and the admin API key are equally sensitive.

## How it works today (implemented)

| Step | Where | Details |
|---|---|---|
| Private key storage | [`deps.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/backend/app/deps.py), [`signing.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/backend/app/signing.py) | `LocalSigner`: an EC P-256 PEM key, from the environment variable `OTA_SIGNING_KEY_PEM` or the file `OTA_SIGNING_KEY_PATH` (Docker volume `…_keys`, mounted at `/data/keys`, file mode 600, directory 700). Held unencrypted in the API process memory. One key (`OTA_SIGNING_KEY_ID`) at a time. Never copied into the Docker image (`backend/.dockerignore`) |
| Key creation | [`keygen.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/backend/app/keygen.py), `scripts/generate_dev_signing_key.sh` | `python -m app.keygen --pem` prints a key for a secret store; `python -m app.keygen` writes the file and refuses to overwrite one. Local setup creates a development key `local-dev-1`. `OTA_AUTO_GENERATE_SIGNING_KEY=true` (the development default) creates a key if none exists; production startup checks refuse it |
| Signing | [`routers/admin.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/backend/app/routers/admin.py) `upload_patch_artifact` | When an admin uploads a patch file, the server builds the canonical message ([`canonical.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/backend/app/canonical.py), ADR-0002) and signs it: ES256 (ECDSA P-256 + SHA-256), raw `r‖s`, base64 |
| Signed fields | `canonical.py` / [`canonical.dart`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/lib/src/canonical.dart) | Protocol version, application id, release id, patch number, platform, arch, runtime ABI, artifact format, base / payload / result SHA-256, size |
| Public key distribution | `GET /v1/admin/signing-key` (admin key required), `ota key show [--dart]` | The developer compiles `{key_id: public key}` into the app (`OtaConfig.publicKeys`). Several keys may be trusted |
| Verification on the device | [`ota_client.dart`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/lib/src/ota_client.dart), [`signature.dart`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/lib/src/signature.dart) | Unknown `key_id` → refused. ES256 verified over the canonical message **before downloading**, using the application and release ids from the response, which must match `OtaConfig.applicationId`. Then exact size and SHA-256 of the download |
| Code patches | [`aot_runtime.dart`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/lib/src/aot_runtime.dart) | The store `libapp.so` must match the signed base hash; the rebuilt `libapp.so` must match the signed result hash |
| Native start | [`OtaBoot.java`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/android/src/main/java/io/github/punitsoni22/flutter_ota_system/OtaBoot.java) | Before loading, checks that the patch id is a UUID, the file is `<files dir>/…/<id>/libapp.so`, its size, and its SHA-256 against the value written by Dart into `boot.json` (hashed once per file, then cached by id, size and modification time) |

## Known limitations (verified in the code)

| Limitation | Effect |
|---|---|
| The private key is held by the server (`LocalSigner`) | Anyone who controls the server process or reads the key can sign patches that devices accept |
| The server signs every upload authenticated by the **one shared admin API key** | A stolen admin key is as dangerous as a stolen signing key. No users, roles, MFA, approvals or audit log |
| One key signs patches for **every application** on the server | Isolation between apps relies on the signed application id, not on separate keys |
| `boot.json` is **not signed** | Native start trusts the SHA-256 that Dart wrote into it. Someone who can write into the app's private storage (root, or a restored backup) can make it load other code |
| Native start does **not** repeat the ES256 verification | The signature is checked once, in Dart, before download |
| The verification cache uses id, size and modification time | Tampering that keeps these unchanged skips re-hashing |
| Patch id and download URL are **not** in the signed message (protocol v1) | Mitigated by strict client checks (lowercase UUID ids; HTTPS-only URLs in release builds; redirect checks). Signing the patch id is a protocol v2 requirement |
| Rollback, revocation and release-id information in update-check responses is **not signed** | Whoever controls the response (the server, or the network if TLS is broken) can make a device fall back to an **older, validly signed** patch of the same release (the anti-replay check allows the server-named rollback target) or to the store build. A new unsigned patch can never be installed |
| No key rotation tooling; apps trust only compiled-in keys | Replacing the key requires new store builds that trust the new key |

## If the private key is compromised

An attacker with the key can sign patches for every app that trusts it. Devices accept them only
from an update-check response the attacker controls (your server, DNS or TLS), so check those
too.

1. **Contain:** stop the API or cut admin access. Revoke every patch you did not publish
   (`ota patch revoke`).
2. **Assess** server, DNS and TLS for compromise.
3. **Rotate:** create a new key with a new `key_id`, configure the server, and ship **new store
   builds** that trust only the new key (and a new backup key).
4. **Retire:** once old builds are gone, delete their releases so they get no more patches.
5. **Disclose** as your obligations require.

## If the private key is lost

No new patch can be signed for installed builds that trust only that key. Recovery means
**new store builds** that trust a new key. Prevent this with an encrypted offline backup and by
shipping builds that already trust a pre-generated backup key.

## Rotation today

- The **client** accepts several keys (`publicKeys` is a map), so a build can trust a current and
  a backup key.
- The **server** signs with one configured key. Switching means changing `OTA_SIGNING_KEY_*` and
  restarting. Patches signed earlier keep their old `key_id` and signature.
- There is no automated rotation, key expiry or revocation list.

## Operator responsibilities

These are practices for the people who run a server. The project does not enforce them.

- Keep private keys out of Git and out of Docker images (the repository's `.gitignore`,
  `backend/.dockerignore` and CI secret scanning help; they do not replace care).
- Use a separate key per environment: never let a production app trust `local-dev-1` or any
  development key.
- Restrict filesystem and secret-store access to the API's service identity; run the API as a
  dedicated non-root user (the image does).
- Protect the admin API key like the signing key; restrict admin network access.
- Encrypt backups: `deploy/backup.sh` copies the key file and the database **unencrypted** into
  `./backups`.
- Keep an encrypted offline copy of the key and a written recovery procedure.
- Keep access logs for `/v1/admin` and your own change records (there is no built-in audit log).
- Plan rotation: ship builds that trust a backup key.

## Future: Azure Key Vault signer (not implemented)

**Nothing on this section exists in the code today.** It describes a possible integration.

Azure Key Vault supports EC P-256 keys and the `ES256` signing algorithm, including HSM-backed
key types, and exposes a `sign` operation so the private key does not leave the service
([About keys](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys-details)). A
self-hosted deployment could:

- create an EC P-256 key (HSM-backed, e.g. Key Vault Premium or Managed HSM);
- give the API a **managed identity** with permission to `sign` (and read the public key) only;
- add a `KeyVaultSigner` that implements the existing `Signer` interface in `signing.py`: send the
  SHA-256 digest of the canonical message to Key Vault, convert the result to raw `r‖s`;
- keep the existing device-side verification unchanged, because the algorithm stays ES256.

This would keep the key out of server memory, files and backups. It would **not** remove the
other limitations above: whoever can call the signer through the API can still get patches
signed, so admin authentication, approvals and audit logging remain necessary. The design is
listed as planned in the [roadmap](roadmap/README.md#planned--not-implemented).

## Related

- [security.md](security.md): security model, threat model, device authentication
- [privacy-and-data-handling.md](privacy-and-data-handling.md)
- [operations.md](operations.md): deployment and backups
