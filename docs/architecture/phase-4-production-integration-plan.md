# Phase 4 production integration plan (Phase 4A audit)

Status: **audit complete, implementation not started**. Date: 2026-11-12.

Branch `feature/phase4-production-integration`, based on `main` at `2be84d2`. Phase 3C is on main as `9f16ad5`; the same content was committed earlier as `23e4592`. Phase 3 is `9fad46b`.

Experimental alpha. Android arm64 only. Pinned toolchain: Flutter 3.47.9, Dart 3.13.7, engine `89c39edf`, Dart `416e33b`.

## 1. What exists today

There are two separate worlds.

### 1.1 Production (what users of `0.1.0-alpha.1` get)

**SDK.** `packages/ota_client` is published as the package `flutter_ota_system`.

- **Public API:** `OtaClient(OtaConfig(serverUrl, appSlug, applicationId, releaseVersion, publicKeys, runtime))`, with the methods `boot()`, `markBootSuccessful*()` and `checkForUpdate()`.
- **Patch formats:**
  - `mock-v1`;
  - `aot-bidiff-android-v1`: a bsdiff of the store `libapp.so`, loaded natively by `OtaBoot` through `--aot-shared-library-name`.
- **What the patch replaces:** the whole compiled `libapp.so`. There is no interpreter.
- **Configuration:** passed only through the constructor. Values arrive as `--dart-define`s that the developer writes by hand.

**CLI.** `cli/` is a Python tool called `ota`.

- It uses the developer's **global** `flutter`.
- `ota release android` registers a fingerprint and uploads `libapp.so`.
- `ota patch android` rebuilds, diffs and uploads.
- Apps are addressed by **slug**.

**Backend.** FastAPI and PostgreSQL, migrations up to `0003`.

- **The server signs every patch** with one key shared by all apps (`backend/app/signing.py`; message `OTA-PATCH-V1`, no `patch_id`, no expiry).
- There is no key rotation, and revocation is not signed.
- The update check sends release version, channel, current patch, supported formats and failed ids. **It does not send `libapp.so` hash, engine or toolchain.**
- Rollout uses HMAC buckets per channel. Rollback and revoke exist.

**Continuous integration (CI).** The end-to-end test only covers `mock-v1`.

### 1.2 Prototypes (Phases 1-3C, under `prototypes/`)

**Custom engine** (`bytecode_engine`):
- the Dart dynamic-modules interpreter (GN `--dart-dynamic-modules`);
- the Phase 3C verifier patch (`security_hardening/engine_patch`).

**Toolchain in the lab** (`~/.cache/flutter-ota-lab`):
- a stock Flutter 3.47.9 SDK with our `gen_snapshot`;
- a file-based Maven mirror with our `libflutter.so`;
- an isolated `GRADLE_USER_HOME`;
- the compiler `dart2bytecode`, run from the Dart source tree.

**Patch model** (`real_app_compatibility`):
- A module can only **add** libraries.
- Patchable code lives in **separate packages**. They are copied and renamed by `pkg_rename`, under the closure rule.
- The host calls patched code only through **pre-declared typed slots** (`FeatureSlots`).
- Models, contracts and state are host-owned.

**Security** (`security_hardening`):
- `patch_security`: container `OTAPRT02`, manifest, ES256, certificates, revocation, toolchain id; 69 tests;
- `patch_guard`: FFI and dynamic-call guard;
- a Python signer;
- a host runtime with crash state machine and separate verifier process. It is prototype code with test hooks and hard-coded package names.

## 2. Integration matrix

| Component | Existing implementation | Production integration required | Notes |
| --- | --- | --- | --- |
| Custom engine | Prototype (lab build + verifier patch) | Yes | Engine build in CI, reproducible; the patch is per Dart revision |
| Bytecode compiler (`dart2bytecode`) | Prototype (run from source) | Yes | Ship as an AOT snapshot in the toolchain bundle |
| Bytecode verifier | Prototype (engine patch, verified on device) | Yes | Ships inside `libflutter.so`; keep the reference verifier as a build-time check |
| Flutter SDK / toolchain manager | Missing | Yes | New: download, verify, cache, lock, upgrade |
| Toolchain distribution | Missing | Yes | Overlay bundle (about 18 MB compressed) on top of a stock Flutter SDK; needs a hosting decision |
| CLI release workflow | Partial (Python `ota`, global Flutter, slug) | Yes | Must use the managed toolchain, app UUID and a baseline identity |
| CLI patch workflow | Partial (AOT diff only) | Yes | New bytecode pipeline: closure, rename, guard, compile, verify, sign, upload |
| SDK runtime | Existing package (AOT/mock) | Yes | Add a bytecode runtime: container v2 verification, verifier process, crash state machine, slots |
| Local signing | Prototype (Python signer) | Yes | Developer-side keys, certificates and signing in the CLI; server-side signing is not used for bytecode |
| Backend distribution | Existing (server-signed) | Yes | Developer-signed uploads, trust roots, revocation lists, a bytecode format, a baseline identity; migration `0004` |
| Key rotation | Prototype (`patch_security` certificates) | Yes | Root key per app, certificates, revocation stored and served by the backend |
| Feature dependency analysis | Prototype (`pkg_rename` closure on local packages) | Yes | Automatic package graph; slot and registry generation; **see decision D1** |
| Crash state machine / rollback | Prototype (verified on device) | Yes | Move into the plugin (generic package names, no test hooks) |
| Canonical demo | `packages/ota_client/example` (mock runtime) | Yes | Convert to features-as-packages; add a freezed feature |

## 3. Target architecture

```text
DEVELOPER MACHINE                                         SELF-HOSTED BACKEND        DEVICE
flutter_ota CLI (Dart, pub global)
 ├─ toolchain manager ─ ~/.cache/flutter_ota/toolchains/flutter-3.47.9+ota.N
 │     (stock Flutter SDK + verified overlay: libflutter.so mirror, gen_snapshot,
 │      dart2bytecode/patch_guard/pkg_rename snapshots, toolchain.json)
 ├─ release android ─ custom SDK ─> APK/AAB + baseline.json ──register──> releases ─┐
 │                                                  (no APK upload)                 │
 ├─ patch android ─ graph ─ guard ─ rename ─ dart2bytecode ─ verify ─ sign(local) ──┤
 │                                                 upload signed .otp ─> patches ───┤
 └─ keys (root offline, signer cert) ─register public root/certs─> trust ─────────┘
                                                                                     │
                                         update check / download / revocations <─────┘
                                                             │
                                FlutterOta.initialize()  ── verify (patch_security)
                                   └─ verifier process (same UID) ─ in-VM verifier
                                   └─ atomic activate ─ crash state machine ─ slots
```

The backend never compiles code and never holds patch-signing private keys for bytecode patches.

## 4. Blockers and conflicts with the Phase 4 requirements

Each item needs an owner decision before implementation.

### D1. Feature patching without restructuring (requirement section 9)

**Verified limit:**
- A dynamic module cannot replace a library that is already loaded.
- In the prototype, the app package itself (`lib/features/...`) is never patchable.
- AOT code calls patched code only through a pre-declared slot.

So "edit any file in `lib/features/` with no structural change" is **not achievable** with the proven mechanism.

Options:
- **(a) Proven:** each feature is a local package (`packages/products/`), with shared models, contracts and state in a host package.
  - One typed slot per feature, **generated** by the CLI from the package graph, with a one-time generated registry.
  - Developers move code into packages once; after that they edit normally.
- **(b) Unproven:** one root slot wrapping the entire app.
  - Each patch carries a renamed copy of the whole app package.
  - This needs a very large dynamic interface (`libapp.so` was 5.0 MB before and 21.7 MB after).
  - All app code then runs interpreted, up to 165x slower on CPU-bound paths.
  - Plugin and background isolates stay AOT, and state can be duplicated.
- **(c)** Ship (a) in Phase 4, and run a time-boxed research spike on (b).

Freezed and json_serializable have **never been tested** with `dart2bytecode` and `patch_guard`. That is a required early spike for any option.

### D2. CLI

The prompt asks for `dart pub global activate flutter_ota_cli` and the command `flutter_ota`, but the existing CLI is Python `ota`, used by the docs, scripts and CI.

Proposal:
- A new **Dart** package `flutter_ota_cli` for developer commands.
- Keep Python `ota` unchanged for server administration (apps, channels, rollouts) and for the existing `mock` and AOT flows.

### D3. Toolchain hosting and supported hosts

**Bundle.** Proposal: an overlay bundle with signed metadata.
- It contains our `libflutter.so` (BSD-licensed engine), `gen_snapshot`, three tool snapshots, `toolchain.json` and the notices.
- The bundle is applied to a stock Flutter 3.47.9 SDK, which the CLI installs into its own cache from the official release archive.
- Mirrors are configurable.
- Publishing the bundle (for example on GitHub Releases) needs the owner's approval. Phase 4 develops and tests against a local file mirror.

**Developer hosts.** Our host binaries are **linux-x64 only**: `gen_snapshot` and the snapshots. macOS and Windows would need separate engine host builds, which do not exist. Proposal: Linux x64 hosts only in Phase 4, documented.

### D4. Signing and backward compatibility

Proposal:
- A new artifact format, `dbc-v1`, which is the `OTAPRT02` container signed by the developer.
- The server verifies the signature against registered trust roots, certificates and revocation lists, but never signs.
- The existing server-signed path stays unchanged for `mock-v1` and `aot-bidiff`, so existing devices are not broken.
- Migration `0004`:
  - per-app trust roots;
  - certificates;
  - revocation lists;
  - baseline identity columns;
  - manifest storage.

### D5. A `flutter_ota.yaml` with only `app_id`

Today devices register with the app **slug**, and admin routes use the slug.

Proposal:
- The backend accepts the UUID, as an additive change.
- The CLI injects the server URL, root public key(s), baseline id and toolchain id into the build as a generated asset or dart-defines.
- The server URL comes from `flutter_ota config set server-url` or the environment variable `FLUTTER_OTA_SERVER_URL`.
- Admin credentials stay outside the yaml.

### D6. Isolation and malformed headers (known from Phase 3C)

- Flutter cannot start in an Android isolated process in a release build. The verifier runs in a **same-UID separate process**.
- About 40 header-level malformed files abort that process. The app stays alive.

Both limits are kept and documented. Converting the header-level aborts into clean errors would need reader hardening in the engine, which means one engine rebuild. Proposal: do it once, together with any other engine change, only if time allows.

### D7. Scope and time

Phase 4 as specified is **several weeks of work**, not one session:
- a toolchain manager;
- a new Dart CLI;
- an SDK bytecode runtime;
- a backend protocol and migration;
- generators;
- a demo;
- documentation.

The plan below lists milestones with separate commits, so the work can be reviewed step by step.

## 5. Implementation order (after decisions)

| Step | Work | Output | Targeted tests |
| --- | --- | --- | --- |
| 4A | This audit and an ADR | this document | none |
| S1 (spike) | freezed / json_serializable through `pkg_rename`, `patch_guard`, `dart2bytecode` and the verifier | spike report | Linux build of a freezed feature module |
| 4B | Toolchain manager + bundle builder (owner side) + `flutter_ota toolchain list/doctor`, lockfile | `flutter_ota_cli` toolchain module | download, hash/signature, cache, interrupted download, corrupt archive |
| 4C | SDK bytecode runtime: `FlutterOta.initialize()`, `patch_security` moved into the package, plugin version of the verifier process and crash state machine | `flutter_ota_system` update (no breaking change) | runtime security tests, startup timing on the phone |
| 4D | `flutter_ota init/doctor/release android`, baseline identity | release pipeline | release command, baseline determinism |
| 4E | `flutter_ota patch android`: graph, guard, rename, compile, verify, local sign, upload | patch pipeline | dependency-graph and bytecode tests |
| 4F | Slot and registry generator (per decision D1); generated-code checks | feature patching | model, freezed and API integration tests |
| 4G | Backend `dbc-v1`, trust and revocation endpoints, migration `0004`, UUID registration | backend changes | modified endpoints + migration test |
| 4H | `status`, `rollback`, `upgrade`, keys; developer and owner guides | workflows | CLI tests |
| 4I | Canonical demo converted; end-to-end on the phone | demo | the 9-step flow from requirement section 9 |
| 4J | Completion report | report | targeted only |

Each step is a separate local commit. Nothing is pushed, merged or published without approval.
