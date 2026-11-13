# Phase 2 prototype: real-app compatibility of the bytecode patch engine

> **Research prototype. Not production code.** It reuses the Phase 1 toolchain
> ([../bytecode_engine/](../bytecode_engine/)): a Flutter 3.47.9 engine built from unmodified
> upstream source with `--dart-dynamic-modules`, run on Android arm64. Tested on Linux (build)
> and one Android 13 arm64 phone only. No signatures, no network delivery (`adb push`).

Results are summarised in [docs/feature-patching.md](../../docs/feature-patching.md) and
[docs/limitations.md](../../docs/limitations.md); the full Phase 2 report and compatibility matrix
are kept in the Git history.

## What is here

```text
real_app_compatibility/
├── app/                      host app "compat_host" (bootstrap, patch runtime, probes, instrumentation)
│   ├── lib/
│   │   ├── main.dart             boot, health watch (crash guard + live fallback), host services
│   │   ├── patch_runtime.dart    .otp validation, store, failure counter, blacklist, exit reasons
│   │   ├── probe_runner.dart     loads experiment modules from inbox/probes/ (deleted before load)
│   │   ├── host_ui.dart          screens + host-owned overlay asset bundle
│   │   └── instrumentation.dart  UI text dump, frame timings, memory, results files
│   ├── android_overlay/MainActivity.kt   ApplicationExitInfo channel (prototype only)
│   └── assets/               config.json, strings_en.json, logo.png
├── packages/                 the app's internal packages (dependency graph below)
├── patches/                  patch modules (Part 4/12/13 scenarios)
│   ├── patch_v1 … patch_v5, patch_v3_stale
│   └── crash/                test-only failure variants (entry_*.dart)
├── probes/                   experiment modules (language, state, UI, plugins, FFI, assets, ...)
├── tools/
│   ├── pkg_rename/bin/pkg_rename.dart   Dart-aware rename + closure + classification tool
│   └── policy.yaml                      host-owned / SDK / runtime packages
├── scripts/
│   ├── build_host.sh         builds the host APK + baseline (link kernel, interface, sources)
│   ├── gen_interface.py      generates the dynamic interface (full or core)
│   ├── make_module.sh        builds one module (.otp)
│   ├── build_modules.sh      builds every module; failures are recorded as results
│   ├── patch_variants.py     damaged/incompatible patch files for recovery tests
│   └── device_suite.py       physical-device acceptance suite (PASS/FAIL/BLOCKED/NOT_TESTED)
└── results/                  text results of the recorded run (no screenshots)
```

### Package dependency graph

```text
compat_host (app)
├── feature_catalog ──► app_core ──► app_models ──► meta
│        │   └──────► shared_state ──► app_models
│        ├──► product_service ──► patchable_utils
│        │        └──► collection (hosted)
│        └──► crypto 3.0.6 (hosted)
├── feature_profile ──► app_core, user_service ──► shared_state, app_models
├── shared_preferences 2.5.5 (plugin: Dart + native Android)
├── compat_suites (test fixtures: language suite, benchmarks, boundary helpers)
└── dynamic_modules (3-line loader wrapper; must have this name)
```

Host-owned (never copied into a module): `app_core` (slot contracts, DI, registry), `app_models`
(shared models), `shared_state` (global/singleton state). See `tools/policy.yaml`.

## How a patch works in this prototype

1. The host calls every patchable feature through a **slot** typed by a host contract
   (`FeatureSlots.catalog` is a `CatalogFeature`). The AOT implementation is the default.
2. A patch is a package (`patches/patch_vN/`) with an `entry.dart` written against the
   **original** package names, `overlay/<package>/…` files with the changed sources, and a
   `module.yaml` listing the changed packages.
3. `pkg_rename prepare` copies each changed package to `<name>_<suffix>`, applies the overlay,
   and rewrites `package:` URIs in import/export/part/part-of/conditional directives using the
   Dart analyzer's parser. It refuses the patch when an unchanged package the module reaches
   depends on a changed one (stale dependency), or when a host-owned package is changed.
4. `dart2bytecode` compiles the module against the baseline's link kernel and validates it
   against the host's dynamic interface. Unchanged packages are **referenced**, not copied.
5. At start-up the host validates the `.otp`, loads the module with the Dart VM interpreter and
   applies the slots the entry point returns (values of the wrong type are ignored).

## Requirements

- The Phase 1 lab, already built: see [../bytecode_engine/README.md](../bytecode_engine/README.md)
  (`fetch_engine.sh`, `build_engine.sh`, `prepare_toolchain.sh`). Phase 2 rebuilds nothing in it.
- Linux x86_64, Python 3, `adb`, an Android arm64 device (USB debugging).
- The pub cache must contain `crypto 3.0.8` and `shared_preferences 2.5.6` (Scenario D and the
  plugin probe copy them); `flutter pub get` fetches them if needed.

## Reproduce

```bash
cd prototypes/real_app_compatibility
export LAB=~/.cache/flutter-ota-lab
unset OTA_API_URL

# 1. Host app + baseline (prints the baseline directory on the last line). ~2 min, throttled.
BASE=$(./scripts/build_host.sh | tail -1)

# 2. All modules (patches, crash variants, probes) -> $LAB/work/otp/modules.tsv
./scripts/build_modules.sh "$BASE" "$LAB/work/otp"

# 3. Optional: the minimal-interface host (size comparison and "new store release" test).
CORE=$(IFACE=core ./scripts/build_host.sh | tail -1)

# 4. Device suites (phone connected; the app is uninstalled/installed once, data cleared per test).
python3 -I scripts/device_suite.py --baseline "$BASE" --otp "$LAB/work/otp" \
  --results "$LAB/results/p2/run" --suites ui,probes,crash,perf
python3 -I scripts/device_suite.py --baseline "$BASE" --otp "$LAB/work/otp" --no-install \
  --results "$LAB/results/p2/compat" --suites compat --release2-apk "$CORE/app-release.apk"
```

Each suite writes `results.tsv` / `results.json` plus per-test logs, the app's result JSON and
screenshots. Screenshots can show the phone's status bar: review before sharing.

Dependency graph and package classification:

```bash
D=$LAB/engine/engine/src/flutter/third_party/dart
$LAB/flutter/bin/cache/dart-sdk/bin/dart --packages=$D/.dart_tool/package_config.json \
  tools/pkg_rename/bin/pkg_rename.dart graph --packages-root "$BASE/src/packages" \
  --host-lock "$BASE/pubspec.lock" --pub-cache ~/.pub-cache --policy tools/policy.yaml
```

## Device protocol (prototype only)

Files under `/sdcard/Android/data/io.github.punitsoni22.compat_host/files/`:

| Path | Meaning |
|---|---|
| `inbox/patch.otp` | new patch; validated, then moved to private storage |
| `inbox/probes/*.otp` | experiment modules; each is deleted before it is loaded |
| `inbox/ROLLBACK` | remove the active patch |
| `inbox/mode` | `home`, `catalog`, `profile` or `feed:<seconds>` |
| `inbox/DUMP` | write another UI snapshot |
| `inbox/STORE_TRUNCATE` | test hook: truncate the stored patch (torn write) |
| `results/*.json` | boot, ui_N, frames, probe_* results |

Logcat lines are prefixed with `[compat]` (for example `LOADED`, `CONFIRMED`, `FAILURE_COUNT`,
`ROLLED_BACK`, `REJECTED`, `LIVE_FALLBACK`).

## Machine load

The scripts run builds with `nice`, at most 2 Gradle workers, no Gradle/Kotlin daemons left
behind, and the bytecode tools as AOT snapshots (a module compiles in about 0.2 s).
