# ADR 0001 (architecture series): Bytecode patch engine and developer experience

- **Status:** Proposed. The Phase 1 prototype succeeded on a physical Android 13 arm64 device
  ([phase-1-prototype-report.md](../phase-1-prototype-report.md)). Not approved for implementation.
- **Date:** 2026-11-12
- **Scope:** replaces only patch **generation** and patch **execution**. Backend, database,
  device management, releases, channels, rollouts, signing, admin dashboard, artifact storage,
  CI/CD and self-hosted deployment stay.
- **Numbering:** this is ADR 0001 of the `docs/architecture/adr/` series. It is unrelated to
  [docs/adr/0001-runtime-abstraction.md](../../adr/0001-runtime-abstraction.md), which it builds on.

Labels: **[Verified]** checked against primary sources or by our prototype · **[Assumption]**
not yet verified · **[Decision]** what we choose.

## 1. Problem

Flutter OTA System's experimental Android code patches rebuild and load a native `libapp.so`
(see [platform-compatibility.md](../../platform-compatibility.md)). That approach:

- produces **native executable code** outside Google Play: a significant policy concern
  ([policy/google-play.md](../../policy/google-play.md));
- relies on an internal Flutter engine flag (`--aot-shared-library-name`) that can change silently;
- has no path to iOS;
- requires developers to run several tools and understand releases, ABIs and keys.

We want a sustainable engine with a better policy position and a developer experience as simple as
Shorebird's, on our own infrastructure.

## 2. Existing architecture (kept)

```
flutter_ota_system SDK ── HTTPS ──▶ FastAPI + PostgreSQL ──▶ artifact storage / CDN
   PatchRuntime interface            releases, patches, channels, rollouts, ES256 signing
   (MockPatchRuntime, AotPatchRuntime)
ota CLI (Python, operator): apps, releases, patches, rollouts
```

The platform is format-agnostic: `artifact_format` and `runtime_abi` are free strings (no database
constraint) and the SDK selects behaviour through `PatchRuntime` **[Verified]**.

## 3. Target architecture

```
DEVELOPER                                   SELF-HOSTED SERVER (unchanged)
flutter_ota release android                  register release + upload baseline
  ├─ managed toolchain: pinned Flutter + OUR engine (Dart interpreter compiled in)
  ├─ generated bootstrap + dynamic interface
  └─ APK/AAB for the store  +  baseline (app.dill, interface, identity)
flutter_ota patch android                    store signed patch (new artifact_format)
  ├─ detect changed pure-Dart packages
  ├─ rename them, compile to Dart bytecode (dart2bytecode) against the baseline
  ├─ validate against the dynamic interface
  └─ package + upload (server signs ES256)
DEVICE
  FlutterOta.initialize()  → existing check/download/verify flow (ES256, SHA-256, anti-replay)
  next cold start          → bootstrap verifies the module, loads it with the Dart VM interpreter,
                             patched packages run as bytecode, everything else stays AOT
  failure / rollback       → existing boot confirmation + server rollback → baseline AOT code
```

## 4. Why the native AOT mechanism is insufficient for our distribution strategy

- It downloads data that becomes a native `.so` and executes it: the provision Google Play names
  explicitly **[Verified, policy text]**.
- It depends on an engine flag Flutter does not support for this purpose; Flutter closed a request
  for it as "not planned" (flutter/flutter#162206) **[Verified]**.
- It cannot be ported to iOS.

It remains available as an experimental option (strategy A).

## 5. Why a bytecode / interpreter architecture

- The Dart SDK contains an official bytecode interpreter and loader ("dynamic modules"), open
  source and BSD-licensed **[Verified]**.
- Interpreted bytecode is closer to Google Play's VM/interpreter exception than native code
  **[Policy interpretation, uncertain]**.
- It needs no private components, unlike Shorebird's iOS interpreter **[Verified]**.
- flutter_patcher 1.x demonstrates the approach end to end **[Verified, source]**.

## 6. Flutter and Dart engine requirements

- The interpreter is compiled **out** of every stock Flutter engine (`dart_dynamic_modules = false`;
  loading throws "Loading of dynamic modules is not supported.") **[Verified]**.
- Required: a custom **build** (not a fork) of `libflutter.so` and `gen_snapshot` from pinned
  upstream source with the official GN flag `--dart-dynamic-modules` **[Verified, Phase 1: no source patches needed]**.
- Additional source patches only when a feature needs them (flutter_patcher carries one Dart VM fix
  for factory constructors in modules and two Flutter patches for assets and background entry
  points) **[Verified, source]**. Phase 1 uses **no** source patches.
- A new store release is required to adopt the engine; it cannot be delivered by OTA.

## 7. Dynamic module generation

`dart2bytecode` from the pinned Dart SDK source compiles module code with `--target flutter`,
`--platform <flutter_patched_sdk_product/platform_strong.dill>`, `--import-dill <baseline app.dill>`
and `--validate <dynamic_interface.yaml>` **[Verified, Phase 1]**. The import must be a separate
non-AOT link kernel (`--no-aot --no-tfa --no-link-platform`), and `dart:core` must be listed in the
interface **[Verified, Phase 1]**. It is experimental and not
shipped in any SDK; our toolchain ships it.

## 8. Runtime loading

A package named `dynamic_modules` (the only non-SDK package name the kernel target lets import
`dart:_internal`) wraps `loadDynamicModule(bytes:)` **[Verified]**. The loader runs the module's
`@pragma('dyn-module:entry-point')` function and receives the patched functions.

## 9. Package-level patching

Dynamic modules can only **add** code; they cannot replace existing declarations **[Verified]**.
A patch therefore carries a **renamed copy** of each changed package (e.g. `package:greeting` →
`package:greeting_patch`), and the host calls the patched copy instead of the AOT one through a
generated indirection. Granularity: **whole package** (not function). State in the AOT copy is
not shared with the patched copy **[Assumption]**.

## 10. Application bootstrap

The CLI generates the bootstrap so the developer's `main.dart` stays one call:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterOta.initialize();
  runApp(const MyApp());
}
```

`FlutterOta.initialize()` (proposed name) reads build-time settings, applies a staged patch,
loads the active module, and starts background checks. Calls into patchable packages are routed
through generated indirections. How much rewriting this needs for real apps is an open question
(section 20).

## 11. Custom toolchain distribution

- The CLI downloads a **pinned toolchain bundle** per Flutter version (our `libflutter.so`,
  `gen_snapshot`, `dart2bytecode` snapshot, manifest with SHA-256 and our signature) from a
  location we control, and builds with an isolated Gradle home and a local Maven mirror
  **[Decision; technique verified in Phase 1]**.
- Bundles are built reproducibly in CI from upstream source plus recorded patches.
- The developer's global Flutter installation is never modified.

## 12. Signing and verification

Keep the existing ES256 canonical message and keys ([signing-key-management.md](../../signing-key-management.md)):
base hash = baseline fingerprint, payload = module archive, result = module. Add **native**
re-verification before every load and sign `patch_id` (protocol v2). The Phase 1 prototype checks
integrity and identity only (no signature).

## 13. Rollback

Unchanged server rollback/revoke and client bad-patch lists. On device: a boot-attempt marker; a
start that does not confirm drops the patch; any load error falls back to the baseline AOT code
(verified on a physical device in Phase 1; crash-loop guard with a crashing module not yet tested).

## 14. Self-hosted backend integration

New `artifact_format` (e.g. `dbc-android-v1`) and `runtime_abi` per toolchain build; baseline stored
as a release artifact; endpoints unchanged; the `public_store` policy gate also covers the new
format. Existing releases, patch history and devices are preserved; new store builds register as
new releases.

## 15. Developer experience

| Step | Command | What happens |
|---|---|---|
| Install SDK | `flutter pub add flutter_ota_system` | Runtime SDK in the app |
| Install CLI | `dart pub global activate flutter_ota_cli` | Provides the `flutter_ota` command |
| Server | `flutter_ota config set server-url https://ota.example.com` | Stored in the user's CLI config |
| Initialize | `flutter_ota init` | Writes `flutter_ota.yaml` with only `app_id`; validates it against the server |
| Integrate | `await FlutterOta.initialize();` in `main` | One call |
| Release | `flutter_ota release android` | Toolchain, build, baseline upload, APK/AAB for the store |
| Patch | `flutter_ota patch android` | Detect, compile, validate, package, upload (server signs) |
| Status | `flutter_ota status` | Releases, patches, rollout state |
| Rollback | `flutter_ota rollback` | Server-side rollback of the current patch |

**`flutter_ota.yaml`** contains only:

```yaml
app_id: "YOUR_OTA_APPLICATION_UUID"
```

`app_id` is the **server application UUID** (`"id"` from `ota app list`; bound into every patch
signature) — not the Android package name, the slug or the Android namespace **[Verified]**. The
device API registers by **slug** (`DeviceRegister.app`), so the CLI looks the slug up from the
UUID at build time (or a later backend change accepts the UUID) **[Decision]**.

**Configuration precedence** (CLI): command-line flag > environment variable
(`FLUTTER_OTA_SERVER_URL`, `FLUTTER_OTA_API_KEY`) > user config file
(`~/.config/flutter_ota/config.yaml`, mode 0600). CI uses environment variables.

**What reaches the app** (as `--dart-define`s injected by the CLI): server URL, app UUID, slug,
release version, public signing keys. **Never** the admin API key or any private key.
A build made with plain `flutter build` has no settings, so `FlutterOta.initialize()` disables OTA
and logs a warning instead of failing.

**CLI distribution [Decision]:** a separate Dart package `flutter_ota_cli`, installed with
`dart pub global activate`, providing `flutter_ota`. Rejected: an executable inside
`flutter_ota_system` (would put CLI-only dependencies into every app's dependency graph); the
existing Python `ota` CLI stays the operator tool. The CLI checks that its version matches the SDK
version in the app's `pubspec.lock`.

## 16. Supported and unsupported changes

| Change | Phase 1 status |
|---|---|
| Pure-Dart code in the app's own packages | Supported by design; one package verified on a physical device in Phase 1 |
| Pure-Dart dependencies | Supported by design (renamed copies) **[Assumption]** |
| Flutter framework | Not patchable (host code) **[Verified, flutter_patcher source]** |
| Native plugins, Kotlin/Java, FFI | Not patchable; modules cannot make FFI calls in AOT runtimes **[Verified, source]** |
| Manifest, Gradle, native assets, Flutter SDK upgrade | Need a store release |
| Assets | Not in Phase 1 (flutter_patcher needs an engine patch) |

The CLI rejects unsupported changes at build time (compile-time validation against the dynamic
interface; package classification).

## 17. Flutter compatibility strategy

One pinned stable Flutter version per toolchain bundle (Phase 1: **3.47.9**, engine `89c39edf`,
Dart 3.13.7). Each new Flutter version: rebuild engine and compiler, rerun the compatibility suite,
publish a new bundle, and app teams ship a store release. Releases record `flutter_version`,
`engine_revision` and `runtime_abi`.

## 18. Licensing

Flutter and Dart: BSD-3-Clause; our engine builds must ship their notices. flutter_patcher (MIT)
is a technical reference only; no code is copied, and it is credited. Our code: Apache-2.0,
"The Punit Authors".

## 19. Google Play policy

Bytecode run by an interpreter fits the wording of the Device and Network Abuse exception better
than native code, and module code cannot call FFI. It is **not automatically compliant**: the
self-update sentence, the interpreted-code clause and content policies still apply. No approval is
claimed. Not legal advice.

## 20. Risks and unresolved questions

- Dart dynamic modules are experimental and may change or be removed upstream.
- Interpreted code is slower; performance limits are unmeasured.
- Rewriting a real app so patchable packages are called through indirections, at scale (many
  packages, classes crossing the boundary, global state) is unproven.
- Engine bytecode-reader bugs (e.g. factory constructors) may need our own VM fixes.
- Toolchain bundle distribution, signing and reproducibility need infrastructure.
- iOS is out of scope; a separate engineering and Apple policy review would be needed.

## Strategy comparison

| | A. Existing AOT replacement | **B. Own bytecode engine** | C. Shorebird-like toolchain |
|---|---|---|---|
| Engine | Stock | Custom build, official flag | Deep fork |
| Private components needed | No | No | Yes (iOS interpreter) |
| Google Play position | Weakest | Better, uncertain | Android same as A |
| Independence | Fragile flag | Upstream sources | Not achievable |
| Decision | Keep as experimental | **Preferred** | Rejected |

B is preferred because it is the only option that is independent, upstream-based and policy-better;
the prototype must prove feasibility before any production work.
