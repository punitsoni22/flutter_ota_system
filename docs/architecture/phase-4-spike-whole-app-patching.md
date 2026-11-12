# Phase 4 research spike R1: whole-app patching

Status: research only. Experimental alpha, Android only. Date: 2026-11-12.

**Compile-level evidence only. Nothing was run on a device. Nothing here is promised to developers yet.**

## Question

Can developers edit normal `lib/` code with no restructuring, if the store build wraps the app in a single root slot? In that design, each patch carries a renamed copy of the whole app package, plus any changed dependencies. The owner decided on this research in decision D1 of [phase-4-production-integration-plan.md](phase-4-production-integration-plan.md).

## Method

- Modules were built with `pkg_rename` and `dart2bytecode` against the Phase 3C host baseline (its `link.dill` and dynamic interface), following the `make_module.sh` conventions.
- `patch_guard` was run on the result.
- No APK or Gradle build was made, and no device was used.

## Results

| Module | Contents | Interface | Result | Size (`module.bc` / gzip) |
| --- | --- | --- | --- | --- |
| wa1 | copy of the host app package; entry returns a builder for the root widget | baseline | compiles | 11,180 B / 6,065 B |
| wa2 | same, but the entry returns the copied `main` (whole package, 1,061 lines) | baseline | fails: 151 errors, all from the host's own patch runtime, which is outside the interface | — |
| wa2a | same as wa2 | generated from `link.dill` | compiles (219 ms) | 51,038 B / 26,413 B |
| wa3 | app + 7 internal packages + `crypto` + `shared_preferences` (41 files) | generated | compiles (380 ms); `patch_guard` reports 0 findings | 119,950 B / 56,868 B |
| wa4 | typical patterns: sealed classes, records, enums with members, extensions, `part` files, private mixins on `State`, `ChangeNotifier`, `Timer`, `compute`, `Isolate.run`, `MethodChannel` | baseline and generated | compiles | 22,715 B |
| wa5 | a new package the host never used (`path`) | generated | fails; compiles with `dart:_internal` added (whether the store build accepts that is not verified) | — |
| wa5m | `flutter/material.dart`, which the host never compiled | generated | **fails, 230 errors** (private framework members) | — |

**Hard limit:** a patch can only use Flutter and Dart libraries that the store build already contains. The interface can be generated automatically by listing the libraries in `link.dill` (785 usable). Building it from the package configuration fails, because only libraries present in the host kernel can be listed.

## Behaviour (analysis; needs device confirmation)

- **Swap all of `main`, not just the root widget.** All app types in the copy are new types. Setup done by the store's `main()`, such as service-locator registrations or statics, would not be visible to the copy. Swapping the whole `main` makes all app setup run inside the copy.
- **Never rename plugin or `*_platform_interface` packages.** The plugin registrant and native code stay AOT. Method channels work (shown in Phase 2).
- **Background isolates and callback handles are high risk.** This covers FCM background handlers, WorkManager and alarms. They start from the store code with no module loaded, so they may run old code or fail. `compute` and `Isolate.run` with bytecode closures are untested.
- **Performance:** all app code runs interpreted. Phase 2 measured widget construction 17x slower and business logic up to 165x slower, with no frame regression in the scrolling test. Heavy screens are a risk.
- **Patch size:** about 20–50 bytes per source line. A 50,000-line app would be about 1–2.5 MB (0.5–1.2 MB gzip), and **every patch is full size**.
- **Cold start:** the VM reads all declarations and bytecode at load time. The estimate is tens of ms for small apps and hundreds of ms to more than 1 s for large ones. Not measured.
- **Store binary size:** not measured. Phase 2 measured `libapp.so` growing from 5.0 to 21.7 MB for Flutter's core layers alone. Whole-app mode also needs Material, Cupertino and every third-party package to be extendable, so it is expected to be larger.

## Coexistence with feature packages

- A root patch that keeps the host contract package shared can live alongside feature slots.
- Simplest rule: a root patch replaces all feature patches.
- **Store-build change required:** build from a generated wrapper (`-t .ota/main.dart`) that calls `FlutterOta.boot(app.main)`. The patch runtime must live in the SDK package, never in the app's own `lib/`.

## Verdict

**Feasible with limits.** Compiling works, but it is not yet a product promise.

The open risks are:
- store binary size;
- interpreted performance;
- cold-start time;
- background isolates;
- the fact that every patch is full size.

## Device experiment needed before any commitment

1. A host built with the generated interface plus Material, Cupertino and `dart:_internal`. Record the `libapp.so` and APK sizes.
2. The main-swap wrapper, with wa2a and wa3. Measure load time, verification time, time to first frame and memory.
3. State checks: service locator, statics, plugin registrant, `shared_preferences`.
4. `compute`, `Isolate.run` and a background callback handle from patched code.
5. Frame timings on a realistic screen.
6. Rollback to the store code when a whole-app patch crashes.
