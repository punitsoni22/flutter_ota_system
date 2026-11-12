# Phase 2 report: real Flutter application compatibility of the bytecode patch engine

**Status:** compatibility research with an isolated prototype. Not production code.
**Prototype:** [prototypes/real_app_compatibility/](../../prototypes/real_app_compatibility/) ·
**Matrix:** [bytecode-compatibility-matrix.md](bytecode-compatibility-matrix.md) ·
**Recorded results:** [prototypes/real_app_compatibility/results/](../../prototypes/real_app_compatibility/results/README.md) ·
**Decision record:** [ADR 0001](adr/0001-bytecode-engine-and-developer-experience.md) ·
**Phase 1:** [phase-1-prototype-report.md](phase-1-prototype-report.md)

## 1. Summary

The Phase 1 engine (Flutter 3.47.9, engine `89c39edf`, Dart 3.13.7, unmodified upstream source
built with `--dart-dynamic-modules`) was reused unchanged; nothing was rebuilt. A multi-package
host app was built with it, and 23 bytecode modules (patches, crash variants, probes) were built
against it and run on a physical Android 13 arm64 phone.

**What works (measured on the phone):**

- Patching one package, two interdependent packages, a package plus unchanged dependencies, a
  changed pure-Dart dependency (`crypto` 3.0.6 → 3.0.8), and a transitive change, with Dart-aware
  package renaming.
- A real screen change, `Product price: ₹499` → `₹399`, from patched Dart code, plus patched
  navigation, `FutureBuilder`/`StreamBuilder`, animation and form validation.
- Shared state and class identity when the host owns the contracts, models and state.
- 49 of 49 Dart language features tested give exactly the AOT result when interpreted, including
  factory constructors.
- Plugins through host services (and a patched plugin Dart wrapper), assets through a host overlay
  bundle (no engine change).
- Crash recovery: crashes before and after the first frame, exceptions in `build()`, throwing
  modules, damaged files: always back to the baseline, never a crash loop.

**What does not work or is unsafe:**

- **FFI** in a module compiles and passes validation, then **aborts the process**.
- **Malformed bytecode** that passes the file checks **aborts the process** in the VM loader (the
  crash guard recovers, but the VM itself is not defensive).
- **Dynamic calls** are refused by default; when allowed, a call to a host member not exposed as
  `dynamically-callable` **returned a wrong value** instead of failing.
- A **copied** model or state package creates separate types and separate state; host contracts,
  models and state can only change with a store release.
- Everything a patch may use must be in the host's **dynamic interface**, fixed at store-build
  time; exposing the Flutter framework made `libapp.so` **4.3× larger** (5.0 → 21.7 MB).
- Interpreted CPU-bound code is **1.5× to 165× slower** than AOT.

All 12 success criteria are met (section 16), with the limits stated there. This is an experimental
alpha tested on one Android phone; no production readiness, no platform support beyond that, and
no Google Play approval are claimed.

## 2. Environment and method

| Item | Value |
|---|---|
| Device | CPH2375, Android 13 (API 33), arm64-v8a, 60 Hz display, USB-connected |
| Build host | Linux x86_64 |
| Toolchain | Flutter 3.47.9 (`c197ca5`), engine `89c39edf`, Dart 3.13.7 (`416e33b`), NDK 28.2 (Phase 1 lab) |
| Build mode | release (the custom engine has no profile build; no debug results are used) |
| Host APK | 35.4 MB (`libapp.so` 21.7 MB) with the full interface |

Method:

- **One instrumented host**, several baselines. Experiments are bytecode modules pushed by `adb`:
  patches into `inbox/patch.otp` (validated, stored privately, loaded at start-up) and probes into
  `inbox/probes/` (each deleted before loading, so a crashing probe cannot loop).
- **Differential testing**: the language suite and benchmark kernels exist once in the host (AOT)
  and once as a renamed copy in a module (interpreted); results are compared one to one.
- **Evidence**: logcat lines (`[compat] …`), JSON results written by the app (UI text dump with
  route and slot sources, frame timings, memory, probe results), and screenshots (kept locally).
- Every device test is recorded as PASS, FAIL, BLOCKED or NOT_TESTED by
  [`scripts/device_suite.py`](../../prototypes/real_app_compatibility/scripts/device_suite.py).

Two harness defects were found and fixed before the recorded run, and every suite was then run
again from a clean state:

- results from an earlier start could be read as the current start's;
- `pm clear` is refused from adb on this phone, so app state was not reset between tests. A
  test-only `RESET_STORE` marker now wipes the private patch store; reinstalling for every test was
  rejected because it triggers a Play Protect prompt.

Only the clean run is reported.

## 3. Application architecture

```text
compat_host (app: boot, patch runtime, probes, instrumentation, screens, overlay asset bundle)
├── feature_catalog ──► app_core, app_models, shared_state, product_service, crypto
├── feature_profile ──► app_core, app_models, user_service
├── product_service ──► app_models, patchable_utils, collection
├── user_service    ──► app_models, shared_state
├── patchable_utils     (export, part/part-of with a .g.dart file, conditional import, import cycle)
├── app_core        ──► app_models, flutter      host contracts: slots, DI, registry, navigation
├── shared_state    ──► app_models               globals, singleton, event bus
├── app_models      ──► meta                     shared models, enums, sealed classes
├── shared_preferences 2.5.5 (plugin), crypto 3.0.6, collection (hosted)
├── compat_suites   (test fixtures)
└── dynamic_modules (loader wrapper)
```

The full graph of 40 packages with their classification is in
[results/dependency_graph.json](../../prototypes/real_app_compatibility/results/dependency_graph.json).

**Host-owned contract (verified).** The host calls every patchable feature through a slot typed by
a host interface (`FeatureSlots.catalog` is a `CatalogFeature`). AOT implementations are the
default. A patch module's entry point returns replacement implementations; the host applies only
values of the right type. Unchanged host packages are referenced by the module, never copied.

## 4. Multi-package patching (Part 4)

| Scenario | Module | Result on the phone |
|---|---|---|
| A: only `feature_catalog` changes | `patch_v1`, 5.5 KB | PASS: new screen version, new widget, tap callback |
| B: `feature_catalog` + `product_service` (+ `feature_profile`) | `patch_v2`, 15.5 KB | PASS: `₹399` on home and catalogue |
| C: patched package uses unchanged `app_models`/`shared_state`/`product_service` | `patch_v1` | PASS: prices from the host's service, cart and counter in the host's state |
| D: `crypto` 3.0.6 → 3.0.8 | `patch_v4`, 26.9 KB | PASS after a host interface change (see below) |
| E: `patchable_utils` (transitive) with its dependents | `patch_v3`, 7.6 KB | PASS: `₹499.00` |
| E without dependents | `patch_v3_stale` (forced) | Change invisible: module's `formatPrice` gives `₹499.00`, screen shows `₹499` |
| F: several modules | probes | Communicate through host types only; duplicate library URIs refused safely; `--prefix-library-uris` avoids the clash |

Findings:

- **Unchanged dependencies are referenced, not copied.** The strings table of the `patch_v1`
  module names only `package:patch_v1/entry.dart` and `package:feature_catalog_patch1/…` as its own
  libraries; `app_models`, `shared_state`, `product_service`, `crypto` are references into the host.
- **Closure rule.** A changed package's unchanged dependents, if the module reaches them, must be
  in the patch. `pkg_rename` enforces it (refusal recorded for `patch_v3_stale` without its
  experiment flag).
- **Scenario D first failed at compile time.** `crypto` extends `dart:convert` classes
  (`Converter`, `ByteConversionSink`); the host's interface made only `dart:core/async/collection`
  extendable. The validator reported it (13 errors) before any artifact existed. It compiled after
  a **new host build** with `dart:convert` and `dart:typed_data` extendable. The interface is part
  of the store build.
- **Modules cannot import other modules.** `dart2bytecode` accepts one `--import-dill` (the host).
  Modules share code only through host types; the same library URI in two modules is refused by
  the VM (`StateError: … is already loaded`), and the app continues.

## 5. Package renaming and import rewriting (Part 5)

`tools/pkg_rename` (Dart, using the pinned SDK's `package:analyzer` parser):

- copies each changed internal or hosted package to `<name>_<suffix>`, applies the patch's overlay
  files, and rewrites `package:` URIs **only** in `import`, `export`, `part`, `part of` and
  conditional-import directives (edits at AST offsets; no text search/replace);
- writes pubspecs that pin the whole graph to the host's `pubspec.lock`;
- reports `package:` strings outside directives and `packages/<name>/` asset keys without changing
  them;
- supports an explicit host reference next to a copy (`// pkg_rename:keep`);
- refuses modules with stale dependencies, host-owned packages, `dart:ffi` or web-only imports
  (exit code 3 with reasons).

All constructs in Part 5 were exercised (`patchable_utils` has an export, a part/part-of pair named
like generated code, a conditional import and an import cycle).

**Indirection.** The prototype's slots are written by hand in `app_core`. A production generator
would have to create or require them. Automatically rewriting an arbitrary app so that every
changed package is reached through a slot is **not demonstrated**.

**Missing or failing patch.** With no patch, or when loading fails, the slots keep their AOT
implementations (measured in the crash suite).

## 6. Shared state and class identity (Part 6)

Probe `probe_state` (38 checks) used the host's packages and, deliberately, renamed copies of
`app_models` and `shared_state`. Results:

- **Through host packages everything is shared.** This covers runtime type, `is`, casts, `==`,
  `hashCode`, field writes seen by AOT code, JSON round trips, `const` canonicalisation (a module's
  `const Product` is `identical` to the host's AOT `const`), enums, top-level variables, statics,
  singletons, lazy `late` values, the DI container, logger, config, auth/session and the event bus
  (both directions).
- **Cross-boundary calls all work.** This covers callbacks, Futures, Streams, `async*`, exceptions
  both ways, reified generics, and a host interface implemented in the module and called by the host.
- **Copies are different types with their own state.** A copied `User` is not a host `User`
  (`TypeError: type 'User' is not a subtype of type 'User'`). A copied singleton has its own state
  (`currentUser` null). Events on a copied bus never reach the host.

Compatibility table:

| Area | Status |
|---|---|
| Host-owned models, state and services used from modules | Supported |
| Module objects registered with host services | Supported |
| Changing a model, state or contract package | Requires full release |
| Copying a model or state package into a module | Unsupported (separate identity and state) |
| Exposing host members for dynamic calls | Unsupported in practice (section 7) |
| Generated indirection for arbitrary apps | Requires further research |

## 7. Dart language compatibility (Part 7)

49 of 49 features compiled, loaded, executed and matched the AOT result. The full table is in the
[matrix](bytecode-compatibility-matrix.md#5-dart-language-part-7); highlights:

- factory constructors (cache, subtype), redirecting factories, const canonicalisation;
- sealed classes with patterns, records, extension types;
- `async*`/`sync*`, timers, zones, and `Isolate.run` with an interpreted closure.

The Phase 1 concern about factory constructors did not reproduce for these cases.

**Dynamic calls** (`probe_dynamic`):

- They are a compile error by default (`Dynamic calls are not allowed in dynamic modules by default`).
- With the opt-in flag `--allow-dynamic-calls-in-dynamic-modules`, every selector must be exposed or
  listed in `--extra-selectors-allowed-in-dynamic-calls`.
- On the phone:
  - calls on module classes worked;
  - `jsonDecode(s)['id']` threw `NoSuchMethodError`;
  - `User` (listed as `dynamically-callable`) worked;
  - `AppConfig.environment` (**not** listed) **returned a different wrong integer each call**, in 3
    separate runs, where typed access returned `prototype`;
  - `AppConfig.apiBase` (not listed) threw.
- **Rule: modules must not use dynamic calls.** Untyped JSON code must be written with types.

**FFI** (`probe_ffi`): it compiled and passed validation. On the phone the process aborted:
`Abort message: '../../flutter/third_party/dart/runtime/vm/runtime_entry.cc: 1754: error:
unreachable code'`. The generator must refuse `dart:ffi` itself.

`flutter analyze` reports one intentional warning in the suite (`unnecessary_type_check`: the
reified-generics test checks `<int>[1] is List<num>`).

## 8. Flutter UI compatibility (Part 8)

All 10 items in Part 8 were verified on screen, via the UI text dump with route and slot sources,
real `adb input tap` events, and screenshots:

- a changed widget and a new widget (`SaleBadge`);
- `StatelessWidget`/`StatefulWidget` and `build` changes;
- callbacks;
- navigation logic (the patched screen pushes `detail (patch 2)`);
- state logic;
- form validation (`Name must have at least 3 characters`);
- asynchronous UI (`p1 stock: in stock`, `live ticks: 5`).

The host navigates to the patched feature, and the result comes from patched Dart code. Probe
`probe_ui` used, inside a live route pushed on the host Navigator:

- `Widget`, `BuildContext`, `State`, `StateSetter`;
- `Navigator` push/pop with a result;
- `AnimationController` with `SingleTickerProviderStateMixin` (a host mixin applied to a module class);
- `MediaQuery`, `LayoutBuilder`, `CustomPainter`, post-frame callbacks;
- `FutureBuilder`, `StreamBuilder`.

This requires the Flutter `src/` libraries in the host interface (section 13).

## 9. Plugins, FFI and native boundaries (Part 9)

| Case | Result |
|---|---|
| Module → host wrapper (`KeyValueStore`) → `shared_preferences` | Works |
| Module → plugin's Dart API (AOT) directly | Works |
| Renamed copy of the plugin Dart wrapper 2.5.6 (host has 2.5.5) | Works; reads and writes visible both ways (same native store) |
| Module → raw `MethodChannel` to the host's native code | Works |
| Channel with no native handler | `MissingPluginException` (safe) |
| FFI | Process abort (section 7) |
| Kotlin/Java/C++/JNI, manifest, Gradle | No mechanism; full release |

Updating the **Dart wrapper** of a plugin is possible when its platform-channel API is unchanged.
Updating the **native implementation** always needs a store release. The classification is in the
[matrix](bytecode-compatibility-matrix.md#1-package-classification-for-the-future-patch-generator)
and is computed for all 40 packages by `pkg_rename graph`.

## 10. Assets (Part 10)

No engine change was needed for the following, measured on the phone:

- **Patched code reads APK assets.** It used `rootBundle` and decoded the APK logo (4×4).
- **Patched code uses images embedded in the module.** Decoding gave 2×3.
- **Fonts can be registered at runtime** (`FontLoader`).
- **A host-owned overlay `AssetBundle`** (installed as `DefaultAssetBundle` by the host) serves
  bytes that the patch carries. With `patch_v2`, **unpatched AOT widgets** showed the patched
  `config.json`, the patched localisation strings, and a replaced logo (8×2 instead of 4×4, through
  `Image.asset`).

Limits:

- code that calls `rootBundle` directly bypasses the overlay;
- new keys are not in `AssetManifest`;
- assets cannot be removed;
- `pubspec`-declared fonts and native assets need a store release;
- asset bytes inside a module count toward its size and download.

## 11. Performance (Part 11)

Release build, same phone, 60 Hz display, USB-connected, other apps in the background as normally
used. Interpreted results come from a module; AOT results from the same source in the host.

**Start-up** (10 cold starts each, `am start -W` TotalTime; in-app `main()` → first frame):

| State | TotalTime median (avg, p90, worst) ms | main→first frame median ms | Module load ms |
|---|---|---|---|
| No patch | 434 (435.3, 443, 445) | 143.6 | – |
| Patch v2 active (15.5 KB) | 453 (458.7, 467, 501) | 154.4 | 1.8 (median and worst 1.9) |
| After rollback | 440 (445.6, 476, 482) | – | – |

Measured cost of an active patch at start-up: about **+19 ms** (+4 %) on this device.

**Memory:**

| State | Total PSS (dumpsys) | RSS / peak RSS at first frame |
|---|---|---|
| No patch | 117.2 MB | 205.5 / 205.5 MB |
| Patch v2 | 117.4 MB | 205.1 / 205.1 MB |
| After the benchmark module ran (repeated use) | – | 215.3 / 215.4 MB |

**Scrolling** (`feed` screen, 100 000-row `ListView` whose rows are built by the catalogue slot;
20 s of `adb input swipe`; Flutter `FrameTiming`; budget 16.7 ms):

| Rows built by | Frames | Build median / p90 / p99 / worst ms | Raster median / p90 / p99 / worst ms | Frames over budget |
|---|---|---|---|---|
| AOT (no patch) | 1056 | 2.57 / 3.46 / 4.62 / 19.93 | 3.03 / 4.21 / 7.00 / 14.83 | 1 |
| Interpreted (`patch_v2`) | 1089 | 2.86 / 3.90 / 4.55 / 15.60 | 3.16 / 4.02 / 5.16 / 12.99 | 0 |

**Execution** (25 timed runs after 3 warm-ups each; with 25 samples p99 equals the worst value):

| Kernel | AOT median ms | Interpreted median ms (p90 / worst) | Slowdown |
|---|---|---|---|
| Simple function calls (200 k) | 0.81 | 26.5 (27.4 / 28.9) | 32.8× |
| Business logic (3 k carts) | 0.33 | 53.8 (54.0 / 54.4) | 165× |
| Collection processing (20 k) | 25.5 | 97.7 (98.7 / 99.5) | 3.8× |
| JSON encode + decode | 8.37 | 12.6 (14.2 / 14.6) | 1.5× |
| String building (20 k) | 4.50 | 55.2 (55.7 / 56.9) | 12.3× |
| Widget construction (4 000 rows) | 1.05 | 17.9 (19.2 / 20.0) | 17.0× |
| async/await (5 k awaits) | 3.22 | 14.4 (15.4 / 15.9) | 4.5× |

All checksums were equal. Interpretation:

- **Tight Dart loops pay the most** (33–165×).
- **Code that mostly calls AOT SDK or framework code pays little.** `jsonDecode`, sorting and
  `Future` machinery run AOT even when called from bytecode.
- **Ordinary UI code showed no measurable frame regression** at this load.

**Artifacts:**

| Item | Size |
|---|---|
| Host APK, full interface | 35.4 MB (`libapp.so` 21.7 MB) |
| Same app, minimal interface (`dart:core` + `app_core`) | 18.8 MB (`libapp.so` 5.0 MB) |
| Modules | 0.6 KB (throwing entry) to 27 KB (`crypto` copy or benchmark suite); typical feature patch 5.5–15.5 KB |
| `.otp` overhead (manifest) | about 330 bytes |
| Module compile time | 0.13–0.23 s each (tools run as AOT snapshots) |
| Module load time on the phone | 0.28–3.6 ms; 12.5 ms for the 18.9 KB module carrying a copy of the `shared_preferences` wrapper |

**Recommended thresholds (from these measurements, for review):**

- **Patch module load:** under 20 ms at start-up (measured 0.28–12.5 ms; it grows with the code a module carries).
- **Start-up regression:** under 10 % (measured 4 %).
- **Frames over budget while scrolling:** no increase over the AOT build.
- **CPU-heavy loops:** keep them out of patches. Treat a slowdown above 10× in a hot path as a
  reason to ship a store release instead.

Not measured:

- Flutter integration-test timelines (no profile engine);
- devices other than this phone;
- battery.

## 12. Crash recovery (Part 12)

The runtime keeps an attempt marker, a per-patch failure counter (`maxFailures = 2`), a blacklist
(`bad.json`) and Android `ApplicationExitInfo` (API 30+) to tell crashes from user or system stops.
In-process errors before confirmation switch the slots back to AOT immediately ("live fallback").

| # | Scenario | Result |
|---|---|---|
| 1 | Valid patch | PASS: loaded, confirmed, active after restart |
| 2 | Module throws during initialisation | PASS: caught, baseline, count 1/2; second start 2/2 → blacklisted; later starts baseline; re-push rejected as blacklisted |
| 3 | Crash before first frame (SIGABRT), repeated | PASS: start 2 sees `CRASH_NATIVE`, counts 1/2 and crashes again; start 3 counts 2/2, blacklists, runs baseline; start 4 baseline |
| 4 | Crash after first frame, before confirmation; exception in `build()` | PASS: same recovery; `build()` exception → live fallback in the same process, no double counting |
| 5 | App killed before confirmation (`am force-stop`) | PASS: `USER_REQUESTED`, not counted, patch confirmed on the next start |
| 6 | Device restart during activation | NOT_TESTED (would reboot the owner's phone) |
| 7 | Partially written patch file; stored patch torn | PASS: rejected (`module size mismatch`); torn stored copy detected at re-validation |
| 8 | Module loading fails (malformed bytecode, valid manifest) | **FAIL** for "error catchable": the VM aborts the process. PASS for recovery: blacklisted after 2 starts, baseline |
| 9 | Corrupted metadata | PASS: `manifest is not valid JSON` |
| 10 | Multiple consecutive failed starts | PASS (scenarios 2–4, 8) |
| 11 | Rollback, then repeated cold starts | PASS: baseline on all 3 starts |

The app never entered a crash loop. Platform limits:

- `ApplicationExitInfo` exists only on Android 11+. Below that, every unconfirmed start would count.
- The 3-second confirmation window is a prototype value.

## 13. Patch compatibility and baseline rules (Part 13)

| # | Case | Result |
|---|---|---|
| 1–2 | Patches A and B against baseline 1 | Supported |
| 3 | A then B | Supported: B replaces A (B is cumulative) |
| 4 | B compiled against A | Unsupported by the toolchain (one `--import-dill`) |
| 5 | Two packages in one patch | Supported (`patch_v2`) |
| 6 | Host package removed or renamed | Requires full release |
| 7 | Public API of a host contract changes | Requires full release: the module's copy of `CatalogFeature` is a different type, so the host ignored it (`catalog:IGNORED`); `pkg_rename` refuses it by default |
| 8 | Dependency version changes | Supported with restrictions (Scenario D; interface must cover it) |
| 9 | Flutter version changes | Requires full release; a module for another runtime is rejected |
| 10 | New store release installed over an active patch (data kept) | PASS: the old patch was rejected at the next start (`patch is for another baseline build`); the new release ran its own code |

Also verified: moving back from B to an earlier patch A of the same baseline, and rollback to the
baseline.

**Safest rule:**

- Patches are **cumulative**, each **rebuilt against the original store baseline**.
- There is one active patch per baseline.
- A store release starts a new baseline with no patches.
- The dynamic interface is part of the baseline.

## 14. Test results

Recorded run (all suites on the phone, clean state per test):

| Suite | PASS | FAIL | BLOCKED | NOT_TESTED |
|---|---|---|---|---|
| UI and package boundaries (Parts 4, 5, 8, 10, 13) | 12 | 0 | 0 | 0 |
| Probes (Parts 6, 7, 8, 9, 10, F) | 11 | 1 (FFI abort) | 0 | 0 |
| Crash recovery (Part 12) | 14 | 1 (malformed bytecode aborts) | 0 | 1 (device restart) |
| Performance (Part 11) | 6 | 0 | 0 | 0 |
| New store release (13.10) | 1 | 0 | 0 | 0 |
| APK byte-identical to the baseline after each suite | 2 | 0 | 0 | 0 |
| **Total** | **46** | **2** | **0** | **1** |

Off the device:

- **Builds:** all 23 modules compile; both refusal checks (stale dependency, host-owned package)
  exit with code 3.
- **Phase 1 reproduction:** 15/15 PASS.
- **Static checks:** `flutter analyze` (host and packages) found one intentional warning;
  `dart analyze` found no issues in the tool; the shell scripts pass `bash -n`; the Python scripts
  compile.
- **Not run:** `shellcheck` (not installed); `./scripts/prepublish_check.sh` (it rebuilds the demo
  stack). The forbidden-pattern list was checked directly against all new files instead.

Per-test details: [results/README.md](../../prototypes/real_app_compatibility/results/README.md).

## 15. Technical blockers before production

1. **Dart dynamic modules are experimental upstream.** The API and the bytecode format may change.
2. **The VM loader is not defensive.** Malformed bytecode aborts the process. Mandatory
   **signature and hash verification before loading** (ADR 0001 §12), and possibly VM hardening.
3. **FFI aborts the process** and passes the validator. The generator must refuse `dart:ffi` in
   any module code.
4. **Dynamic calls can silently return wrong values** when allowed. Keep them forbidden, and teach
   developers typed JSON access.
5. **The dynamic interface is a store-build decision.** It costs size (+16.6 MB `libapp.so` here)
   and limits what later patches can use. A policy for which libraries to expose is needed.
6. **Indirection.** The prototype's slots are hand-written. Generating or enforcing host contracts
   in real apps (and refusing changes behind them) is unproven at scale.
7. **Modules embed absolute source paths** (`file:///…`) of the build machine. They must be
   stripped or made relative (privacy and reproducibility).
8. **Interpreted CPU-bound code is up to 165× slower.** The generator should warn on hot loops.
9. **Toolchain distribution, signing, server protocol and SDK integration** are not built (out of
   scope for Phase 2).
10. **Evidence is narrow.** One phone, one Flutter version, Android only. The device-restart test
    was not run. `ApplicationExitInfo` needs API 30+.

## 16. Success criteria (Part 16)

| # | Criterion | Met? | Evidence / limits |
|---|---|---|---|
| 1 | Multi-package app builds with our engine | Yes | Build script checks the engine hash in the APK |
| 2 | Two interdependent pure-Dart packages patched together | Yes | Scenario B |
| 3 | Unchanged dependency works with a patched package | Yes | Scenario C |
| 4 | Cross-package interfaces and shared state tested | Yes | Section 6 |
| 5 | Renaming and import rewriting demonstrated | Yes | Section 5 (analyzer-based) |
| 6 | Tested Dart feature matrix | Yes | 49 features, differential |
| 7 | A Flutter UI feature changes through bytecode | Yes | `₹499` → `₹399`, navigation, validation |
| 8 | Plugin, FFI, asset restrictions documented | Yes | Sections 9–10, matrix |
| 9 | Performance measured on a physical device | Yes | Release build; no profile-mode timelines |
| 10 | Real crash and automatic rollback tested | Yes | Except device restart (not tested) |
| 11 | Patch compatibility and baseline rules documented | Yes | Section 13 |
| 12 | Reproducible on Linux | Yes, with a limit | Scripts and README; rebuilt several times in the same lab, not yet on a second machine |

## 17. Recommendation

Keep strategy B (own bytecode engine) for Android, with these Phase 2 rules:

1. **Host-owned contracts.**
   - Contracts, models, state and services live in the host.
   - Patchable features sit behind typed slots.
   - Patches reference host packages and copy only changed `PATCHABLE` packages, with the
     dependency closure.
2. **One cumulative patch per baseline**, compiled against the original store baseline. Use
   `--prefix-library-uris` only if several modules must ever coexist.
3. **Build-time refusal** (as `pkg_rename` does):
   - host-owned or SDK packages;
   - stale dependencies;
   - `dart:ffi`;
   - web-only code;
   - dynamic calls;
   - anything the host interface does not cover.
4. **Runtime safety:**
   - signature and hash verification before loading (mandatory, since the VM aborts on bad
     bytecode);
   - the attempt marker, failure counter and blacklist;
   - `ApplicationExitInfo`;
   - live fallback to AOT for in-process errors.
5. **Explicit interface policy** with a size budget, chosen per app at release time.
6. **Assets** through a host overlay bundle for `DefaultAssetBundle` users; everything else needs a
   store release.

Phase 3 should not start until this report is reviewed.
