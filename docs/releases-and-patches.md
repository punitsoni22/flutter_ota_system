# Releases, patches and rollouts

This page explains the concepts. For the step-by-step commands, see the [quick start](quick-start.md) and the [CLI reference](cli-reference.md).

## Release and patch

**Store release.** The app you upload to Google Play, built by `flutter_ota release android` with the custom engine.
- The server knows it by its **release id**, its version (for example `1.0.0+1`) and the SHA-256 of its compiled `libapp.so`.
- Patches only ever apply to the exact release they were built for.

**Patch.** A signed `dbc-v1` file built by `flutter_ota patch android`. It contains the changed feature packages as Dart bytecode.
- **Cumulative:** each patch carries **every** change since its store release, not only the change since the previous patch. A device needs only the newest patch, never a chain.
- **One active patch:** at most one patch runs at a time. Each patch has a **sequence number**, and devices never accept a lower sequence (replay protection).
- **Never rewrites the store build:** the installed APK and its `libapp.so` stay unchanged.

**A new store release** starts a new line of patches. Old app versions keep receiving only the patches built for them. You need a new store release for:
- changes outside feature packages;
- dependency, native or asset changes;
- a new toolchain.

See [feature patching](feature-patching.md#6-what-needs-a-new-store-release).

## Patch life cycle

```text
patch android ──► draft ──publish──► published ──rollback──► rolled_back ──publish──► published
                                         │
                                         └──revoke──► revoked (permanent)
```

| Status | Meaning |
| --- | --- |
| `draft` | Uploaded and verified by the server, but offered to nobody |
| `published` | Offered on one or more channels, at a rollout percentage |
| `rolled_back` | No longer offered. Devices running it go back to the previous patch or the store code. Can be published again |
| `revoked` | Never offered again. Devices drop it even if it is already downloaded |

**On the device:**
1. At a start, the app checks for updates in the background, after the first frame.
2. A new patch is downloaded, verified and test-loaded in a separate process.
3. It runs from the **next start**.

So a patch reaches a user after **two app starts**. Rollback and revocation also take effect at the next start. Offline devices keep running their last good code.

## Channels

An app has channels, by default `dev`, `staging` and `production`. Each device sends its channel with the update check (the default is `production`). A patch is published to one or more channels, each with its own rollout percentage.

**Protected channels** (`OTA_PROTECTED_CHANNELS`, default `production`):
- Raising a patch's rollout there requires an earlier deployment on another channel, and no reported boot failures. The server enforces this.
- Publish to `staging` first, then promote: `ota patch promote <patch_id> --percent 10`.
- An operator can override with `--force --reason "…"`, and the server logs the reason.

## Staged rollout

A device is included when its **bucket** is below `percentage × 100`. The bucket is 0–9999, from an HMAC of the app id, the installation id and the patch id.
- **Raising the percentage** of the same patch only adds devices; nobody already included drops out.
- **Lowering it** stops new devices from getting the patch. Devices that already installed it keep it; to take it away, roll back or revoke.
- **A different patch** uses different buckets.

**A typical canary rollout:** staging 100% → production 1% → 5% → 25% → 100%.

Watch with `flutter_ota status` (patches, rollout, device summary) and the event counters (`ota patch show <id>`).

## Rollback and revocation

**Rollback** (`flutter_ota rollback`, or `ota patch rollback <id>`):
- The patch becomes `rolled_back`.
- Devices running it get the newest other patch they are eligible for, or the store code, at their next start.
- It can be published again.

**Revocation** (`ota patch revoke <id>`):
- It is permanent. The patch is listed as revoked in every update-check response for that release, and devices drop it at once.

**Signed revocation lists** (bytecode architecture) can also revoke **signer keys and certificate serials**, for example after a key was stolen. See [security](security.md#rotation-revocation-and-recovery).

## Crash protection

A new patch first runs **on probation**:
- If the app crashes before the start is confirmed, or keeps crashing after it, the patch is rolled back on that device, blocklisted, and reported to the server.
- The previous confirmed patch, or the store code, runs instead.
- Force-stops and low-memory kills do not count as crashes.

## Original alpha patch formats

The original alpha `v0.1.0-alpha.1` uses different patch formats, built and signed by the **server**.

| Format | What it contains | Built by |
| --- | --- | --- |
| `mock-v1` | An inert payload (no code); for testing the pipeline | `ota patch create` |
| `aot-bidiff-android-v1` | A binary diff of the store `libapp.so`; the device rebuilds and loads a new compiled `libapp.so` at start | `ota release android` / `ota patch android` |

Channels, rollouts, rollback and revocation work the same way for all formats.

An app uses **either** the original `OtaClient` path **or** the bytecode `FlutterOta` path, not both. The `aot-bidiff` path replaces executable code and is gated by a policy approval for `public_store` apps (`ota app approve-policy`). See [Google Play](policy/google-play.md).
