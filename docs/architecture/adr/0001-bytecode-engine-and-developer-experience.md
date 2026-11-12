# ADR 0001 (architecture series): Bytecode patch engine and developer experience

- **Status:** Proposed. The Phase 1 prototype succeeded on a physical Android 13 arm64 device
  ([phase-1-prototype-report.md](../phase-1-prototype-report.md)). Phase 2 tested real-app
  compatibility on the same device ([phase-2-compatibility-report.md](../phase-2-compatibility-report.md),
  [bytecode-compatibility-matrix.md](../bytecode-compatibility-matrix.md)); its findings are added
  below and labelled **[Verified, Phase 2]**. Phase 3 security hardening
  ([phase-3-security-report.md](../phase-3-security-report.md)) adds findings labelled
  **[Verified, Phase 3]**; one blocker remains open (section 12). Not approved for implementation.
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

**Phase 2 update [Verified, Phase 2].**
- A renamed copy has its own types and state: a copied model is not the host type (cast throws
  `TypeError`), and a copied singleton or event bus is separate.
- Therefore contracts, models, state and services stay in the host (**host-owned contract**).
  Features are reached through slots typed by host interfaces. A module copies only the changed
  `PATCHABLE` packages and **references** the unchanged ones, keeping one identity and one state.
- If an unchanged package the module reaches depends on a changed one, that package must be in the
  patch too (closure rule).
- Import rewriting uses the analyzer's parser and touches only directive URIs.
- Modules cannot import other modules (one `--import-dill`). The same library URI in two modules is
  refused by the VM.
- The indirection was written by hand in the prototype; generating it for arbitrary apps remains
  open **[Assumption]**.

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

**Phase 3 update [Verified, Phase 3]**
([bytecode-validation-architecture.md](../bytecode-validation-architecture.md)).

*Authenticity and integrity are not safety.* Signature, hash and compatibility checks prove who
signed and that nothing changed. A correctly signed module can still contain bytecode that aborts
the Dart VM.

**Decision [Decision, Phase 3] for the production design:**
- A **canonical signed manifest** (prototype container v2). It binds the app id, store release,
  `libapp.so` SHA-256 (hashed on the device), patch id and sequence, runtime versions, the
  dynamic-interface hash, the module hash and size, and the package list. Signatures are
  domain-separated, and signed revocation lists are supported.
- Every patch passes the full pipeline before any module loader sees it.
- The stored patch is re-verified at every start.
- A **new** patch is first loaded in a separate Android process (`:otaverify`) before it is
  activated. The Dart VM has no validate-only API, reads every declaration and function body at
  load time, and aborts the process on malformed input (`FATAL`; release builds have no
  `ASSERT`s). A malformed module therefore kills only the verifier.
- On the phone, the app survived all 65 corpus files; 47 of 53 signed malformed modules were
  refused.
- Build time: `patch_guard` refuses FFI (the upstream validator accepts it) and dynamic calls
  before `dart2bytecode` runs.

**Open blocker:** the VM does not verify bytecode **instructions**. Two signed modules with
changed opcodes passed the isolated load. They could crash the app when the changed code runs,
until the crash guard rolls back (at most 2 starts). A complete fix needs an instruction verifier
in the engine's bytecode reader, or exclusive reproducible compilation of every signed module.
Both are open.

**Key separation (proposal, not implemented):** the signing key must leave the server (developer
or CI signing), with an offline root key for rotation.
## 13. Rollback

Unchanged server rollback/revoke and client bad-patch lists. On device: a boot-attempt marker; a
start that does not confirm drops the patch; any load error falls back to the baseline AOT code
(verified on a physical device in Phase 1; crash-loop guard with a crashing module not yet tested).

**Phase 2 update [Verified, Phase 2].**
- Real crashes were tested: throws during initialisation, SIGABRT before and after the first frame,
  exceptions in `build()`, damaged files, and a new store release over an active patch.
- The runtime counts failures per patch, blacklists after 2, falls back to AOT in-process for
  errors before confirmation, and uses Android `ApplicationExitInfo` (API 30+) so that a user
  force-stop is not counted. No crash loop was observed.
- **The VM aborts the process on malformed bytecode** that passes the file checks. Signature
  verification **before** loading (section 12) is therefore mandatory, not optional.

**Phase 3 update [Verified, Phase 3].**
- Activation is atomic: staging, then rename, then state, each with fsync, and leftovers are
  removed at start-up.
- The **previous confirmed patch is kept**, and restored when the active patch is blacklisted,
  revoked or found damaged, instead of falling back to the baseline.
- Explicit rollback still returns to the baseline.
- Tested on the phone: a process killed during activation, a torn stored patch, a signed
  revocation, and crashes before and after the first frame. Each state-dependent crash passed the
  isolated load and was rolled back after 2 failed starts.
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

| Change | Phase 1 status | Phase 2 finding |
|---|---|---|
| Pure-Dart code in the app's own packages | Supported by design; one package verified on a physical device in Phase 1 | Supported for packages behind host contracts; several interdependent packages and transitive changes verified **[Verified, Phase 2]** |
| Pure-Dart dependencies | Supported by design (renamed copies) **[Assumption]** | Supported with restrictions: `crypto` 3.0.6 → 3.0.8 as a renamed copy; the host interface must cover what it extends **[Verified, Phase 2]** |
| Host contracts, shared models, shared state | (not covered) | Need a store release (a copy has new identities and state) **[Verified, Phase 2]** |
| Flutter framework | Not patchable (host code) **[Verified, flutter_patcher source]** | Unchanged; patched widgets can use the framework if its libraries are in the interface (size cost: `libapp.so` 5.0 → 21.7 MB for the test app) **[Verified, Phase 2]** |
| Native plugins, Kotlin/Java, FFI | Not patchable; modules cannot make FFI calls in AOT runtimes **[Verified, source]** | A plugin's **Dart** wrapper can be patched if its channel API is unchanged. FFI in a module compiles and passes validation but **aborts the process**: the generator must refuse `dart:ffi` **[Verified, Phase 2]** |
| Manifest, Gradle, native assets, Flutter SDK upgrade | Need a store release | Unchanged |
| Assets | Not in Phase 1 (flutter_patcher needs an engine patch) | Without an engine change, a host-owned overlay `AssetBundle` serves module-carried assets to all `DefaultAssetBundle` users; `rootBundle` callers, pubspec fonts and removals need a store release **[Verified, Phase 2]** |
| Dynamic calls in module code | (not covered) | Refused by default; when allowed, an unexposed host member returned a wrong value: must stay forbidden **[Verified, Phase 2]**. Phase 3: `patch_guard` also refuses them, plus `noSuchMethod` (accepted upstream) and `dart:mirrors` **[Verified, Phase 3]** |
| FFI in module code | (not covered) | Phase 3: refused before bytecode generation, including transitive, conditional, re-exported and generated cases; a signed FFI module that bypassed the guard crashed only the isolated verifier **[Verified, Phase 3]** |

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
- Interpreted code is slower; performance limits are unmeasured. *Phase 2 measured on one phone:*
  - interpreted CPU-bound kernels were 1.5–165× slower than AOT;
  - an active 15.5 KB patch added about 19 ms (4 %) to cold start;
  - scrolling with interpreted row builders showed no frame regression.

  **[Verified, Phase 2]**
- The dynamic interface is fixed at store-build time; it limits later patches and costs app size
  (+16.6 MB `libapp.so` for the full Flutter interface in the test app) **[Verified, Phase 2]**.
- The VM loader aborts on malformed bytecode; FFI and (allowed) dynamic calls are unsafe in modules
  **[Verified, Phase 2]**.
- Modules embed absolute source paths of the build machine; the generator must strip them
  **[Verified, Phase 2]**.
- A correctly signed module with invalid instructions can still crash the app at run time; no
  pre-activation check in the current Dart VM detects it (open blocker, section 12)
  **[Verified, Phase 3]**.
- The patch-signing key is held by the server and one admin key controls uploads; key
  separation, rotation and approvals are not implemented **[Verified, Phase 3 audit]**.
- Rewriting a real app so patchable packages are called through indirections, at scale (many
  packages, classes crossing the boundary, global state) is unproven.
- Engine bytecode-reader bugs (e.g. factory constructors) may need our own VM fixes. *Phase 2:* 49
  language features, including factory and redirecting factory constructors, gave the AOT result
  when interpreted; no reader bug was found in those cases **[Verified, Phase 2]**.
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
