# Phase 1 prototype report: bytecode patch engine

**Result: prototype successful (core path), with documented gaps.** On a physical Android 13 arm64
phone, a pure-Dart package compiled ahead of time into the app was replaced at the next cold start
by **Dart bytecode executed by the Dart VM's interpreter**, without reinstalling the APK and
without replacing `libapp.so`. Rollback and all invalid-patch cases fell back to the baseline.

Date: 2026-11-12. Branch: `prototype/bytecode-engine-phase1`. Code:
[`prototypes/bytecode_engine/`](../../prototypes/bytecode_engine/README.md). Decision record:
[ADR 0001](adr/0001-bytecode-engine-and-developer-experience.md).

> [!IMPORTANT]
> Research prototype only. Not production code, no signatures, one patchable package, delivery by
> `adb push`. Dart dynamic modules are an experimental, unsupported upstream feature. No store
> approval or production readiness is claimed. This is not legal advice.

## 1. Toolchain (pinned)

| Item | Value | Source |
|---|---|---|
| Flutter | **3.47.9**, commit `c197ca5199e9ee5661e865596c9c07294dfab51c` (released 2026-10-29) | tag + `releases_linux.json` |
| Engine | commit `89c39edfdfae2949f6806e4a315c0c08522238b7` (`bin/internal/engine.version`; the tag is 3 framework-only commits ahead) | GitHub compare |
| Dart | **3.13.7**, revision `416e33b0ffaef062a60ec966bb8c82ed2b83f128` (`DEPS`) | verified in checkout |
| depot_tools | `1afcf0756e47f3a6ee82d7736b9fcda2d57b268e` (fetch only) | recorded |
| Android NDK / platform / build-tools | 28.2.13676358 / 36 / 36.1.0 (engine's pinned CIPD bundle `37v2`) | `DEPS`, `config.gni` |
| Target | Android **arm64-v8a**, release | — |
| App build | Flutter's configured JDK (JBR 21.0.11), Gradle 9.3.1 | — |
| Host | Linux x86_64, 16 cores, 15 GiB RAM | — |

All in `~/.cache/flutter-ota-lab/`; the developer's Flutter 3.44.9, PATH, Java, Gradle and Android
SDK were not modified. Pins: [`pins.env`](../../prototypes/bytecode_engine/pins.env).

## 2. Engine changes

| Layer | Change |
|---|---|
| Dart SDK source | **None** |
| Flutter engine source | **None** |
| Flutter framework / tool | **None** (stock 3.47.9 SDK; only its cached `gen_snapshot` replaced in the lab copy) |
| Buildroot / Android embedding | **None** (official embedding jar used unchanged) |
| Build configuration | `flutter/tools/gn --android --android-cpu arm64 --runtime-mode release --no-prebuilt-dart-sdk --dart-dynamic-modules` → `dart_dynamic_modules = true` |
| Built targets | `flutter/shell/platform/android:android_jar`, `clang_x64/gen_snapshot` |

**Proof the interpreter is compiled in** (strings in `libflutter.so`):

| String | Stock 3.47.9 | Ours |
|---|---|---|
| "Loading of dynamic modules is not supported" (disabled path) | present | **absent** |
| "Unexpected Dart bytecode magic" | absent | **present** |
| "Cannot find bytecode object" | absent | **present** |
| `interpreter_trace_file_max_bytes` | absent | **present** |

Our `libflutter.so` (stripped): SHA-256 `5f67f76f…19ddf`; `gen_snapshot`: `5d2d2f6a…2343` (reports
Dart 3.13.7). flutter_patcher's extra patches (a Dart VM fix for factory constructors in modules,
Flutter patches for assets and background entry points) were **not needed** for this prototype.

## 3. Pipeline (verified end to end)

```
app source ──flutter build apk (lab SDK, our gen_snapshot, our libflutter.so via local Maven mirror,
             --extra-front-end-options=--dynamic-interface=dynamic_interface.yaml)──▶ baseline APK
           └─frontend_server --no-aot --no-tfa --no-link-platform ──▶ link.dill (link kernel)
patch source (package:greeting_patch + @pragma('dyn-module:entry-point'))
  └─dart2bytecode --target flutter --platform flutter_patched_sdk_product/platform_strong.dill
                  --import-dill link.dill --validate dynamic_interface.yaml ──▶ module.bc (830 B)
module.bc + manifest ──▶ patch1.otp (1,123 B) ──adb push──▶ device inbox
device: validate → copy to private storage → loadDynamicModule(bytes) → interpreter → v2 greeting
```

Findings that were **not** known before the prototype:

1. The release build's `app.dill` is a tree-shaken whole program; `dart2bytecode` crashes when
   linking against it (null check in `DillExtensionBuilder`). A separate **link kernel**
   (`--no-aot --no-tfa --no-link-platform`) is required.
2. `dart:core` is **not** implicitly available to modules: the dynamic interface must list it as
   `callable` and `can-be-used-as-type`, otherwise `String`, `Object` and `@pragma` fail validation.
   The same interface must be passed to the **host** build.
3. Only a package named `dynamic_modules` (or `dart_internal`) may import `dart:_internal`
   (verified in `pkg/kernel/lib/target/targets.dart`; Flutter's target inherits it). The analyzer
   still reports `import_internal_library`; the compiler accepts it.
4. Gradle must use an isolated home: our artifact has the same Maven coordinates as the stock
   engine, so a shared cache could silently supply the stock engine. The build script verifies the
   APK's `libflutter.so` hash equals ours.

## 4. Runtime loading

- `package:dynamic_modules` (our 3-line wrapper) calls `dart:_internal.loadDynamicModule(bytes:)`.
- The module's entry point returns `{contract: 1, package: 'greeting', greeting: <function>}`; the
  host calls that function instead of the AOT `package:greeting`.
- Patch file `.otp`: `"OTAPRT01"` · u32 BE manifest length · manifest JSON
  (`format, runtime, app_id, baseline_id, patch_number, module_sha256, module_size`) · module.
- Validated on arrival and again at every start; stored in private app storage; a boot-attempt
  marker and a confirm after 3 s; any error → baseline.

## 5. Real-device test

**Device:** model `CPH2375`, **Android 13 (SDK 33), arm64-v8a**, physical, over USB.
**Installed APK SHA-256:** `c032eca0…0267`, `lastUpdateTime` 2026-11-12 14:39:07 — **identical before
and after all scenarios** (no reinstall). Patch logic never touches native libraries; the v2 text
appears 0 times in the baseline `libapp.so` and once in `module.bc` (bytecode magic `DBC3`).

Device log excerpts:

```
no patch:  [ota-proto] greeting="Original implementation: Hello from version 1" source=baseline (AOT, libapp.so)
patch:     [ota-proto] installed patch #1 (1123 bytes) into private storage
           [ota-proto] loading bytecode module (830 bytes) with the Dart VM interpreter
           [ota-proto] module loaded: patch #1 replaces package:greeting
           [ota-proto] greeting="Patched implementation: Hello from version 2" source=patch #1 (bytecode, interpreter)
restart:   (same, loaded again from private storage)
rollback:  [ota-proto] rollback requested: active patch removed, baseline will run
```

Screens: "Original implementation: Hello from version 1 — source: baseline (AOT, libapp.so)" and,
after the patch and a cold restart, "Patched implementation: Hello from version 2 — source: patch #1
(bytecode, interpreter)".

## 6. Test results

| # | Scenario | Result | Evidence |
|---|---|---|---|
| 1 | No patch: baseline runs | **PASS** | v1, source baseline |
| 2 | Valid patch: updated code runs after cold restart | **PASS** | v2 via interpreter |
| 2b | Second cold restart keeps the patch | **PASS** | reloaded from private storage |
| 3 | Corrupted module rejected | **PASS** | "module SHA-256 mismatch" |
| 4 | Wrong module/format version rejected | **PASS** | "unsupported patch format 2"; wrong runtime: "module built for runtime proto-dbc-flutter-3.44.9" |
| 5 | Wrong application identity rejected | **PASS** | "patch is for another application" |
| 6 | Incompatible baseline rejected | **PASS** | "patch is for another baseline build" |
| 7 | Missing module: safe fallback | **PASS** | "module size mismatch", baseline runs |
| 8 | Rollback: original behaviour returns | **PASS** | v1 |
| 9 | Restart after rollback: baseline still runs | **PASS** | v1 |
| 10 | Repeated patch application (×3) + valid patch after all negatives | **PASS** | v2, no corruption |
| 11 | Invalid artifact: no crash loop | **PASS (partial)** | garbage rejected ("bad magic"), app process alive, next start normal |
| — | Crash-loop guard with a module that **crashes** at start | **Not tested** | needs a crashing module variant |
| — | Signature verification | **Not tested** (not implemented in the prototype) | integrity + identity checks only |
| — | Emulator (x86_64 + ARM translation) | **Not tested** (stopped for host load) | physical device used instead |

## 7. Resource usage

| Item | Measured |
|---|---|
| Engine source checkout (incl. Android SDK bundle) | 16 GB |
| Lab total (checkout, builds, side-by-side SDK, Gradle) | 21 GB |
| Engine build outputs | 1.3 GB |
| Engine build time (`-j6`, 6,740 steps) | **12 min 50 s** |
| Peak memory of one build process (final link) | **7.3 GB** |
| Baseline APK (arm64, release) | 16,070,145 bytes (16.1 MB) |
| Patch module / patch file | **830 B / 1,123 B** |

Running an emulator and leftover Gradle daemons alongside other work filled the host's swap; heavy
steps should run on a dedicated machine or CI.

## 8. Patch scope (verified vs. assumed)

| Change | Status |
|---|---|
| Pure-Dart function in an app package, called through a stable entry contract | **Verified** |
| Module using `dart:core` (strings, maps, closures) | **Verified** (requires interface entries) |
| Pure-Dart dependencies, many packages, classes crossing the host/module boundary | Not tested |
| Widgets / Flutter framework types in modules | Not tested (needs interface entries for Flutter libraries) |
| Factory constructors (e.g. `Uint8List.fromList`) in modules | Not tested; flutter_patcher needed a VM fix |
| Flutter framework, plugins, FFI, Kotlin/Java, manifest, Gradle, assets, SDK upgrades | Not patchable by design / store release |

## 9. Security and policy notes

- The patch changes behaviour by **interpreted Dart bytecode**; no native library is downloaded or
  replaced. Module code cannot make FFI calls in AOT runtimes (source-level restriction).
- Google Play's exception covers code run "in a virtual machine or an interpreter where either
  provides indirect access to Android APIs". This prototype is closer to that wording than native
  AOT patches, but it is **not** automatically compliant: the self-update and interpreted-code
  provisions, and content policies, still apply.
- The prototype verifies integrity and identity only. Production needs the existing ES256 signing
  plus native re-verification.

## 10. Open questions and blockers before Phase 2

1. Make a real app patchable: generate indirections for many packages and classes; shared state.
2. Interface generation: which host libraries to expose; tree-shaking cost of exposing Flutter.
3. Factory-constructor VM bug and other bytecode-reader gaps; asset patches.
4. Interpreter performance for real UI code (unmeasured).
5. Toolchain distribution: CI builds of engine + `gen_snapshot` + `dart2bytecode`, signed bundles.
6. Crash-loop guard test with a crashing module; ES256 signature and native verification.
7. Upstream stability: Dart dynamic modules are experimental and may change.

## 11. Verdict

**Prototype successful** for the Phase 1 core goal: a custom engine with the official interpreter
flag, bytecode generation, interpreter execution of an updated pure-Dart package on a physical
device after a cold restart, no APK reinstall, no `libapp.so` replacement, rollback, and rejection
of every invalid artifact tested. The gaps in sections 6, 8 and 10 must be addressed before any
production work.
