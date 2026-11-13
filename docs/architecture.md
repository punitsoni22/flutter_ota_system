# Architecture

Flutter OTA System has three parts:
- your **developer machine** builds and signs everything;
- your **self-hosted backend** verifies, stores and delivers;
- the **user's phone** verifies again and runs the patch.

This page describes the **bytecode architecture** (experimental, unreleased). The [original alpha](#original-alpha-architecture) is summarised at the end.

```text
┌──────────────── DEVELOPER MACHINE (Linux x64) ────────────────┐
│ flutter_ota CLI                                               │
│  ├─ toolchain manager: signed index → Flutter 3.47.9 + overlay│
│  │   (custom engine, gen_snapshot, dart2bytecode, guard,       │
│  │    bytecode verifier, dynamic_modules)                      │
│  ├─ release android: APK/AAB with the custom engine            │
│  ├─ features: dependency graph + generated feature registry    │
│  ├─ patch android: rename → patch_guard → dart2bytecode →      │
│  │   bc_verify → manifest → LOCAL signature                    │
│  └─ keys: offline root key, certified signer key (local only)  │
└──────────────┬──────────────────────────────┬─────────────────┘
               │ register release              │ upload signed dbc-v1 patch
               │ (libapp.so hash, no APK)      │ (never source code)
┌──────────────▼──────── SELF-HOSTED BACKEND ──▼─────────────────┐
│ FastAPI + PostgreSQL + file/S3 storage (+ nginx/Caddy CDN)     │
│  apps & releases · trust roots, certificates, revocation lists │
│  verify signed patches (never signs dbc-v1) · store · deliver  │
│  channels · staged rollouts · rollback · revocation            │
└──────────────┬────────────────────────────────────────────────┘
               │ update check, patch download, revocation list
┌──────────────▼──────── USER'S PHONE (Android arm64) ──────────┐
│ your app (store build) + custom Flutter engine                │
│  FlutterOta.initialize(): verify stored patch → load → run     │
│  background: download → verify signature/hashes/compatibility │
│   → test-load in a separate process (in-VM bytecode verifier) │
│   → activate at next start → crash state machine / rollback   │
└───────────────────────────────────────────────────────────────┘
```

## Developer machine

All compilation and signing happen here, or in your own CI. Nothing is compiled on a server, and no source code is uploaded.

**Toolchain**
- A stock Flutter 3.47.9 SDK, plus our **overlay**:
  - an engine with the Dart bytecode interpreter and our bytecode verifier;
  - `gen_snapshot`, the compiler tools and the `dynamic_modules` loader package.
- The CLI downloads it from a signed index, verifies it, caches it and pins it in `flutter_ota.lock`.
- Your global Flutter is never used. See [toolchain management](toolchain-management.md).

**Store release (`release android`)**
- Builds the APK/AAB with the custom engine from a neutral copy of your workspace, so no personal paths end up in the binary.
- Generates:
  - the **dynamic interface**: which store-build libraries patches may use;
  - `link.dill`: the kernel that patches compile against;
  - the feature registry and the build entry point.
- Keeps a local **baseline** in `.flutter_ota/releases/<id>/`.
- Registers the release and the SHA-256 of `libapp.so` with your server.

**Patch (`patch android`)**
1. Finds the changed feature packages and their dependency closure.
2. Checks that generated code is up to date.
3. Copies and renames the packages.
4. Runs `patch_guard`, which rejects FFI, `dart:mirrors`, internal libraries, dynamic calls and undeclared dependencies.
5. Compiles with `dart2bytecode` against `link.dill`, then runs the reference bytecode verifier.
6. Writes a manifest bound to the exact store build and toolchain, and **signs it locally**.
7. Uploads it.

See [feature patching](feature-patching.md).

**Keys**
- An offline **root key** per app certifies a **signer key** on your machine.
- Private keys stay in `~/.config/flutter_ota/keys/`. See [security](security.md).

## Self-hosted backend

| Module | Responsibility |
| --- | --- |
| [`routers/admin.py`](../backend/app/routers/admin.py) | Apps, channels, releases (with baseline identity), patches, rollouts, rollback, revocation |
| [`routers/trust.py`](../backend/app/routers/trust.py), [`trust.py`](../backend/app/trust.py) | Root public keys, root-signed certificates, root-signed revocation lists |
| [`dbc.py`](../backend/app/dbc.py) | Verifies uploaded `dbc-v1` patches |
| [`routers/devices.py`](../backend/app/routers/devices.py), [`updates.py`](../backend/app/updates.py) | Device registration (by app UUID or slug), update check, events |
| [`bucket.py`](../backend/app/bucket.py) | Deterministic staged-rollout buckets |
| [`storage.py`](../backend/app/storage.py) | Content-addressed storage: local disk or S3-compatible |
| [`auth.py`](../backend/app/auth.py) | Admin API key, device JWTs |
| [`models.py`](../backend/app/models.py), [`migrations/`](../backend/migrations/versions/) | Database tables and Alembic migrations |

**What `dbc.py` checks on upload:**
- the patch is bound to the right app, release and baseline `libapp.so` hash;
- the certificate chain leads to a registered, non-revoked root;
- the signature and any approvals verify;
- the module hash and size match the manifest;
- the patch id is unique and the sequence number is higher than before;
- the patch has not expired.

The server stores the signed file **unchanged**. It **never signs** `dbc-v1` patches and never needs the developer's private keys.

**Storage**
- Files are stored as `<kind>/<sha256>` and never overwritten.
- `patches/` is public: integrity comes from signatures, not secret URLs.
- `releases/` is private.
- Database migrations run automatically at start-up.

**Rollouts**
- Channels, for example `dev`, `staging` and `production`.
- Percentage rollouts, using a stable per-device bucket.
- Protected channels require staging first.
- Rollback (reversible) and revocation (permanent).

See [releases and patches](releases-and-patches.md) and the [API reference](api-reference.md).

## User's phone

The app is the normal store build, built with the custom engine. The `flutter_ota_system` SDK does the work:

1. **At start, before `runApp`**
   - `FlutterOta.initialize()` re-verifies the stored patch: signature, hashes, release, toolchain and revocations.
   - It loads the patch and fills the feature slots.
   - No network request is made on this path.
2. **After the first frame**
   - The start is confirmed after a stable period.
   - The background update check runs.
3. **For a new patch**
   - Download it and verify it again.
   - **Test-load it in a separate process** (`:flutter_ota_verify`). There, the engine's bytecode verifier checks every function before any patch code runs.
   - Store it. It runs from the **next start**; code is never swapped live.
4. **Crash recovery**
   - A crash state machine (DOWNLOADED → VERIFIED → PROBATIONARY → ACTIVE) tracks each patch, using Android exit information to tell crashes apart from force-stops and OS kills.
   - A patch that keeps crashing is rolled back and blocklisted. The previous confirmed patch, or the store code, runs instead.

The installed APK and its compiled `libapp.so` are **never modified**. The patch is a separate signed file in the app's private storage.

Contributor references:
- [runtime contract](architecture/runtime-contract.md): configuration, feature slots, module entry;
- [SDK runtime](architecture/phase-4-sdk-runtime.md);
- [backend protocol](architecture/phase-4-backend-protocol.md);
- [bytecode verifier](architecture/bytecode-verifier.md).

## Original alpha architecture

`v0.1.0-alpha.1` works differently:
- the **server** signs each patch with one server key;
- an Android patch is a binary diff that **replaces `libapp.so`** at start (`aot-bidiff-android-v1`);
- the client is `OtaClient` on stock Flutter;
- the Python `ota` CLI builds and diffs the app.

This path is still in the code for existing users. It is separate from the bytecode architecture, and it carries store-policy considerations, see [Google Play](policy/google-play.md).
