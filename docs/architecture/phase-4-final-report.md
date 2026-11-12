# Phase 4 final report: production integration

Status: **experimental alpha**. Android arm64 only. Linux x64 developer machines only.

This phase integrates the Phase 1–3C prototypes into the product. A real Android phone demonstrated the owner's acceptance criterion. **This is not a claim of production readiness or of Google Play approval.** Comprehensive testing is a separate final phase.

Branch: `feature/phase4-production-integration`, based on `main` at `2be84d2`. All commits are local; nothing was pushed, merged, tagged or published.

## 1. Architecture implemented

```text
DEVELOPER MACHINE (Linux x64)                               SELF-HOSTED BACKEND          PHONE
flutter_ota CLI (Dart)
 ├─ toolchain manager: signed index → stock Flutter 3.47.9 + OTA overlay (custom engine,
 │   gen_snapshot, dart2bytecode, pkg_rename, patch_guard, bc_verify, dynamic_modules)
 ├─ keys init: offline root key + signer key/certificate (stay local) ──public parts──> trust
 ├─ release android: neutral build copy, generated entry + feature registry, dynamic
 │   interface, link.dill, APK/AAB with the custom engine ─register baseline──> releases
 ├─ patch android: change detection → closure → stale-codegen check → rename → guard →
 │   dart2bytecode → bc_verify → manifest → LOCAL signature ──dbc-v1 upload──> verify, store
 └─ status / rollback ──────────────────────────────────────────────> existing admin API
                                                                                │
FlutterOta.initialize() ← update check / download / revocations ←───────────────┘
 └─ verify (signature, certificate, identity, toolchain, hashes) → separate verifier
    process (in-VM bytecode verifier) → atomic activation at next start → crash state machine
```

**Key properties:**
- All builds, bytecode compilation and signing happen locally. No source code is uploaded.
- The backend verifies developer-signed patches but never signs them, and never holds patch-signing private keys.
- The developer never builds or configures the engine. The CLI never uses or changes the global Flutter installation, and never falls back to stock Flutter.

## 2. Production files changed

about 245 files changed in 18 commits (see the PR description for the list).

| Area | Files |
| --- | --- |
| Backend | `backend/app/{dbc,trust,models,schemas,updates,main}.py`, `routers/{admin,devices,trust}.py`, migration `0004`, `tests/test_dbc.py` |
| SDK | `packages/ota_client/lib/**` (FlutterOta facade, OtaFeature, bytecode runtime, security code), Android Java (`OtaRuntimeChannel`, `FlutterOtaVerifierService`, manifest), tests |
| CLI (new) | `packages/flutter_ota_cli/**` |
| Owner tool (new) | `tools/toolchain/**` |
| Guard | `prototypes/security_hardening/tools/patch_guard/**` |
| Demo | `packages/ota_client/example/**` (feature packages) |
| Docs | `docs/architecture/phase-4-*`, `docs/{toolchain-management,cli-reference-flutter-ota,releasing-with-flutter-ota,feature-patching,signing-guide,flutter-integration-v2,demo-walkthrough}.md` |

## 3. Custom engine integration

- **The engine itself is unchanged** from Phase 3C: dynamic modules, plus the in-VM bytecode verifier patch (`engine_patch/0001-dart-bytecode-verifier.patch`). It was not rebuilt in Phase 4.
- **Distribution:** an overlay (about 18 MB compressed) applied on top of the stock Flutter 3.47.9 SDK. It contains:
  - our `libflutter.so`, in a local Maven mirror jar;
  - `gen_snapshot`;
  - the tool snapshots `dart2bytecode`, `pkg_rename`, `patch_guard` and `bc_verify`;
  - the `dynamic_modules` package;
  - `toolchain.json`;
  - licence notices.
- **Engine check at release:** `release android` refuses any APK/AAB whose `libflutter.so` does not match the toolchain's engine.

## 4. Toolchain manager

- **Signed index:** ES256 signature, with a serial number that blocks replay of an old index.
- **Downloads:** disk-space check first, then resume, then SHA-256 and size verification.
- **Installation:** an install lock, extraction in a temporary folder, an atomic rename, and an `install.json` record of file hashes.
- **Commands:** `toolchain list/install/doctor/clean`, and `upgrade`, which asks before changing anything.
- **`flutter_ota.lock`:** generated automatically. It pins the toolchain of the store release.
- **Cache:** `~/.cache/flutter_ota/{toolchains,downloads,metadata,locks}`.
- **Owner tool:** `tools/toolchain/build_bundle.sh` builds a reproducible overlay and a signed index. Keys stay outside the repository.
- **Not yet done:** no official toolchain key is embedded in the CLI, and no index or overlay is published. Both need owner approval.

## 5. CLI commands implemented (`flutter_ota`)

`init`, `config set|get|list|unset`, `toolchain list|install|doctor|clean`, `upgrade`, `keys init|list`, `doctor`, `release android`, `features`, `features generate [--check]`, `patch android`, `status`, `rollback`.

`flutter_ota.yaml` contains only `app_id`. The server URL comes from `flutter_ota config set server-url` or `FLUTTER_OTA_SERVER_URL`. The admin key comes only from `FLUTTER_OTA_ADMIN_KEY`, and is never stored.

## 6. SDK API changes (additive)

New:
- `FlutterOta.initialize()`. It never throws and makes no network call on the start-up path.
- `FlutterOta.feature<T>()`, the abstract class `OtaFeature`, and the getters `status`, `activePatch`, `activePatchId` and `lastStartupTimings`.
- `FlutterOta.checkForUpdate()`.
- `FlutterOta.registerModuleLoader()`. Only CLI-generated code calls it; the developer's `main.dart` stays unchanged.

Unchanged: the existing `OtaClient` / `OtaConfig` / AOT / mock API, the channels and the storage.

## 7. Backend API changes (additive)

- **Format `dbc-v1`:** an `OTAPRT02` container signed by the developer. On upload the server checks:
  - the manifest, and that it binds to the right app, release and baseline;
  - the certificate chain up to a registered root;
  - the signature and approvals;
  - the module hash;
  - that the patch id is unique;
  - the sequence number;
  - the expiry.
- **Trust endpoints:** root keys, root-signed certificates, and root-signed revocation lists.
- **Releases:** optional client-chosen id and baseline identity.
- **Device registration:** by app UUID.
- **Update check:** `dbc-v1` patches and the revocation list are returned only to clients that ask for them. Legacy clients get byte-identical responses.

## 8. Database migrations

`0004_developer_signing`, additive and reversible:
- adds the tables `trust_roots`, `key_certificates` and `revocation_lists`;
- adds baseline identity columns on `releases`;
- adds `dbc-v1` columns on `patch_artifacts`.

Checked on PostgreSQL 17: upgrade `0003` → `0004`, downgrade back, and upgrade again. Data was preserved.

## 9. Feature patching capabilities

- **Proven model:** each feature is a local package with a `<Name>Feature` entry class.
- **Contract:** features are reached through a host-owned type (`OtaFeature`, or an abstract class in a shared package).
- **Generated code:** the CLI generates the registry and the entry wrapper. Developers do not rename packages or write slots by hand.
- **Can be patched:** API logic, feature-owned models (including freezed and json_serializable), entities, repositories, controllers and UI.
- **Dependency closure:** computed automatically.
- **Refused, with the reason "needs a new store release":**
  - changes to the app package itself;
  - changes to shared packages;
  - `pubspec.lock` changes;
  - native code or assets;
  - new local packages;
  - dependencies that are not in the store build.
- **Research:** whole-app patching without restructuring was compiled but not run on a device ([phase-4-spike-whole-app-patching.md](phase-4-spike-whole-app-patching.md)).

## 10. Freezed and generated code

- **Requirements:** freezed ≥ 4.0.3 on Dart 3.13. `explicit_to_json: true` is recommended.
- **Stale generated files:** detected by regenerating in a clean copy and comparing. A stale file is refused with exact instructions.
- **Phone test:** a freezed model field (`rating`) was added, `.freezed.dart` and `.g.dart` were regenerated, and the change was delivered as a patch and worked on the phone (see §13).

## 11. Signing architecture

- **Keys:** an offline root key per app. A local signer key certified by the root, with environment, roles, serial and validity.
- **Lifecycle:** rotation by serial, root-signed revocation of serials and key ids, emergency replacement, approvals. Approvals are verified on Linux; the demo did not require them.
- **Where keys live:** `~/.config/flutter_ota/keys/<app_id>/`, mode 0600. They are never written into the project, the APK or the backend.

## 12. Local build verification

- **Store builds:** they run in a neutral copy of the workspace. A real build had 0 occurrences of the developer's home path in `libapp.so`, the APK and `link.dill`.
- **Reproducible patches:** module builds are reproducible. Two builds from different source folders were byte-identical (Phase 3C).
- **Dynamic interface:** derived from the app kernel. It was byte-identical across two releases of the same app.

## 13. Targeted test results

Each suite ran after its own change, as the global testing strategy requires.

| Area | Result |
| --- | --- |
| Backend | 40 passed (24 existing + 16 new); migration checked on PostgreSQL |
| `patch_guard` | 20/20 harness cases; 9/9 host-list cases |
| SDK `flutter_ota_system` | 237 passed (84 existing, 69 ported security, 84 new runtime); `flutter analyze` clean |
| CLI `flutter_ota_cli` | 193 passed, 3 skipped (opt-in lab tests), including 25 new `status`/`rollback` tests |
| Real runs | toolchain install from a signed local index; real releases on a local backend; a real feature module compiled, verified, signed and accepted by `patch_security` |
| **Phone (Android 13 arm64)** | **acceptance criterion met:** a feature change shipped by `flutter_ota patch android` showed on the installed app after a restart, with no reinstall. APK and `libapp.so` hashes were identical before and after. Rollback returned to the store code. Details: [phase-4-phone-demonstration.md](phase-4-phone-demonstration.md) |
| Privacy and secrets | forbidden patterns 0; gitleaks (history and working tree) clean; no personal paths, keys or demo values in the 18 commits |

**Start-up on the phone:**

| Situation | Time |
| --- | --- |
| No patch | about 110 ms |
| Patch active | 200–260 ms |
| Module load alone | 3.8 ms |
| Separate-process verification of a new patch (background) | 295 ms |

## 14. Known limitations

| Area | Limitation |
| --- | --- |
| Platforms | Android arm64 only; Linux x64 developer hosts only (host tool binaries exist only for Linux) |
| Feature patching | Features must be local packages. The app package and shared packages cannot be patched |
| Isolation | The verifier process has the same UID as the app (Android isolated processes cannot run Flutter in release builds) |
| Corrupt headers | About 40 header-level corrupt modules abort the separate verifier process (contained). They are not rejected cleanly |
| Verifier coverage | The bytecode verifier is not a type checker. Residual risk remains from type confusion into VM runtime entries |
| Store binary size | The full dynamic interface is large: `libapp.so` was about 22–26 MB for small apps. The effect on large apps is not measured |
| Speed | Patched code is interpreted, so CPU-heavy code is slower (Phase 2: up to 165×) |
| Publishing | No official toolchain key or index is published. Approvals were tested on Linux only |
| Promotion | There is no `flutter_ota` command to promote a patch from staging to production (the existing backend rule requires staging first). Use the backend rollout endpoint or the Python `ota` CLI. `flutter_ota rollback` cannot store a reason, because the API has no reason field |
| Release rebuilds | Every release rebuilds Android from scratch, because it builds from a neutral copy |
| Release recovery | A partly failed release registration has no automatic resume |

## 15. Remaining work for the final deep-testing phase

1. More devices and Android versions.
2. Large real apps: binary size, start-up, memory and frame timing.
3. All crash-recovery paths on device with the production SDK:
   - OS eviction;
   - repeated crashes;
   - background isolates.
4. The CI/CD pipeline with the new CLI.
5. Store release compatibility (AAB on Google Play internal testing, without claiming approval).
6. Security fuzzing of `dbc-v1` uploads and of the device verifier.
7. Toolchain upgrades:
   - a second Flutter version built through the owner workflow;
   - `flutter_ota upgrade` across store releases.
8. Whole-app patching device experiment (spike R1).
9. Official toolchain signing key, mirror and publication (owner approval needed).

## 16. Git branch and commits

Branch `feature/phase4-production-integration`, 18 local commits on top of `main` `2be84d2`.

The commits are listed in the PR description. Every commit is authored by "Punit Maintainers", with no co-author trailers.

## 17. Confirmation

Nothing was pushed, merged, tagged, published or deployed:
- no package was published to pub.dev;
- no toolchain was published;
- no engine binary was published;
- no production configuration was changed.
