# Phase 4 spike S1: freezed and json_serializable through the patch pipeline

Status: research. Compile-level and verifier-level evidence only; **runtime behaviour was not tested on a device**. Date: 2026-11-12. Pinned toolchain: Flutter 3.47.9 / Dart 3.13.7.

## Setup

**Test package.** `feature_products` contains:
- two freezed models, `Product` and `Price`, with `fromJson`/`toJson`;
- an enum, `@Default`, `@JsonKey(name:)`, `List`/`Map`/`DateTime` fields and `copyWith`;
- a repository that uses `jsonDecode`/`jsonEncode`;
- a widget.

**Package versions:**

| Package | Version |
| --- | --- |
| freezed_annotation | 3.1.0 |
| json_annotation | 4.12.0 |
| build_runner | 2.16.2 |
| json_serializable | 6.15.2 |
| freezed | 4.0.3 (3.2.5 also tried) |

**Pipeline:** the repository's own `make_module.sh`, unchanged:

`pkg_rename` → `patch_guard` → `dart2bytecode` (against the Phase 3C host's `link.dill` and full interface) → reference verifier `bc_verify`.

## Results

| Stage | Result |
| --- | --- |
| build_runner (freezed 3.2.5) | pass, with an analyzer language-version warning |
| `pkg_rename` (feature package plus both annotation packages renamed) | pass |
| `patch_guard` | pass, 0 findings |
| `dart2bytecode`, freezed 3.2.5 | **fail:** `Can't have modifier 'final' here`. Freezed 3.x writes `final` constructor parameters, which Dart 3.13 rejects in general, not only for OTA. Fixed in freezed 4.0.3. |
| `dart2bytecode`, freezed 4.0.3, unchanged interface | **fail:** `Cannot extend ... 'UnmodifiableSetView' in a dynamic module`. `freezed_annotation`'s `EqualUnmodifiableSetView` extends `package:collection`'s view, which the host does not expose as extendable. |
| With `freezed_annotation` overlaid to use `dart:collection`'s `UnmodifiableSetView` | **pass:** compiled against the unchanged interface; `bc_verify` OK (226 functions, 6,442 instructions; module 45,967 B) |
| Interface extended with `package:collection` (extendable) plus `dart:_internal` | compiles, but exposing `dart:_internal` is **not** recommended |

**Dynamic calls:** the generated code has **none**.
- It uses casts, typed callbacks, `Object.hash` and `DeepCollectionEquality`.
- One implicit dynamic call remains: `jsonEncode` calling a nested `toJson()` when `explicitToJson` is off. Phase 2 device evidence covers this case. `explicit_to_json: true` is still recommended.
- The guard also analyses `part` files: a deliberate dynamic call in `.g.dart` or `.freezed.dart` was rejected.

## Pipeline gaps found

These must be fixed in the production patch pipeline (milestone 4E).

1. **`patch_guard`'s "analyses cleanly" check never fires.**
   - It compares the diagnostic severity with `'ERROR'`, but the runtime value is `error`.
   - As a result, compile errors were reported as accepted.
   - `dart2bytecode` still caught them, but the guard check itself is dead and has no test case.
   - **Fixed:** the guard now compares the analyzer's `Severity.error` enum value. Every compile error becomes an `analysis_error` finding (file and line), and the module is rejected. New fixture cases `compile_error` (error in the library) and `compile_error_part` (error in a `part` file) are rejected; the old guard accepted both.
2. **`patch_guard` coverage hole.**
   - A dependency that is neither a host package nor listed in `external:` is compiled into the module, but it is not passed to the guard as a module package. So that dependency is **not scanned**.
   - `pkg_rename` also wrote an unpinned version constraint for it.
   - Fix: treat every package in the module that is not a host package as a module package, or refuse such dependencies.
   - **Fixed:** the guard takes `--host-packages` (the baseline's `host_packages.json`, or the host's `pubspec.lock`), and `make_module.sh` passes it. Every package in the module's package config that is not a host package (`flutter` and `sky_engine` always count as host) is scanned, together with `--module-packages`. Such a package that the module reaches but that is not declared in `module.yaml` (`change:` or `external:`) is also rejected (`undeclared_dependency`). New fixture cases (`tools/patch_guard/fixtures/host_cases.tsv`, run with `tools/patch_guard/test/run_host_cases.sh`) show that FFI and a dynamic call inside an undeclared dependency are now rejected. Without `--host-packages`, the guard keeps the old behaviour.
3. **Stale generated files are not detected.**
   - Changing a `@JsonKey` name without re-running build_runner passed every tool, so the patch would silently use the old JSON key.
   - Fix: regenerate in a clean copy and compare, or record input and output hashes. Then refuse the patch with clear instructions.

## Conclusion

**Patchable today with workarounds** (compile and verifier level).

Rules for Phase 4:
1. Require freezed ≥ 4.0.3 (or `addImplicitFinal: false`) on Dart 3.13.
2. Recommended: the **host owns** `freezed_annotation` and `json_annotation`. It includes them in the store build and lists them in the generated interface. This needs a new host build, which is not verified yet. Interim: a module-internal copy with the overlay above (verified).
3. Fix guard gaps 1 and 2, and add stale-codegen detection (gap 3), before any patch upload is allowed.
4. Recommend `explicit_to_json: true` in `build.yaml`.

Still to verify on a device: runtime behaviour of freezed and JSON code in a patch; a host built with the annotation packages.
