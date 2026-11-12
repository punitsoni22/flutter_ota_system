# Bytecode patch engine: compatibility matrix (Phase 2)

What a Dart bytecode patch module can and cannot change, measured with the Phase 2 prototype
([prototypes/real_app_compatibility/](../../prototypes/real_app_compatibility/)). Details and
evidence: [phase-2-compatibility-report.md](phase-2-compatibility-report.md).

**Scope of the evidence.** One custom engine (Flutter 3.47.9, engine `89c39edf`, Dart 3.13.7, built
from unmodified upstream source with `--dart-dynamic-modules`), release mode, Android arm64, one
physical phone (Android 13, API 33). Nothing here is verified for other Flutter versions, other
devices, other ABIs, iOS, macOS, Windows or the web. This is an experimental alpha, not a
production-ready system.

**Status words.**

| Word | Meaning |
|---|---|
| Supported | Compiled, loaded and executed on the phone with the expected result |
| Supported with restrictions | Works on the phone only under the stated condition |
| Unsupported | Measured not to work (or to be unsafe) |
| Requires full release | Outside what a module can change; a new store build is needed |
| Not tested | Not measured in Phase 2 |

## 1. Package classification (for the future patch generator)

The prototype tool `pkg_rename` implements these rules and **refuses** to build a module that
breaks them (verified: exit code 3 with the reason).

| Class | Packages | Rule |
|---|---|---|
| `PATCHABLE` | App packages with pure-Dart code behind host contracts (`feature_*`, `*_service`, `patchable_utils`); pure-Dart hosted packages (`collection`, `crypto`, …) | Copied into the module under a new name |
| `PATCHABLE_WITH_RESTRICTIONS` | Plugin packages (Dart side only, e.g. `shared_preferences`); packages that declare assets or fonts | Only the Dart side may change, the platform-channel API must stay the same; a module carries no assets (use the host overlay, §6) |
| `NOT_PATCHABLE` | Anything importing `dart:ffi`; web-only packages (unconditional `dart:js_interop`/`dart:ui_web`/`dart:html`) | Rejected |
| `REQUIRES_FULL_RELEASE` | Host-owned contract/model/state packages (`app_core`, `app_models`, `shared_state`); the patch runtime (`dynamic_modules`); SDK packages (`flutter`, `sky_engine`); Kotlin/Java/C++/JNI, `AndroidManifest.xml`, Gradle, the Flutter version; the dynamic interface itself | Rejected |

Two further build-time rules, both measured:

- **Closure rule.** If an unchanged package that the module reaches depends on a changed package,
  it must be included in the patch. Otherwise the host's unchanged code keeps calling the old
  version: measured with `patch_v3_stale`, where the module's new `formatPrice` produced `₹499.00`
  but the screen still showed `₹499`.
- **Interface rule.** Everything a module uses from the host must be in the host's dynamic interface,
  which is fixed when the store build is made. A patch that needs more interface needs a full
  release (measured: the copied `crypto` package failed validation until `dart:convert` was made
  extendable in a new host build).

## 2. Package boundaries (Part 4 scenarios)

| Scenario | Status | Evidence |
|---|---|---|
| A. One internal package changes (`feature_catalog`) | Supported | 5.5 KB module; host calls the patched screen through its slot |
| B. Two interdependent packages change together (`feature_catalog` + `product_service`, plus `feature_profile`) | Supported | 15.5 KB module; price `₹499` → `₹399` on the home and catalogue screens |
| C. Changed package uses unchanged packages (`app_models`, `shared_state`, `product_service`) | Supported | Unchanged packages are **referenced** from the host, not copied; cart and counters are the host's |
| D. Changed pure-Dart dependency (`crypto` 3.0.6 → 3.0.8) | Supported with restrictions | Renamed copy `crypto_patch4` in the module (26.9 KB); the host keeps 3.0.6. The interface must cover what the dependency extends |
| E. Transitive dependency changes (`patchable_utils` under `product_service` under `feature_catalog`) | Supported with restrictions | All dependents must be in the patch (closure rule); then `₹499.00` is shown |
| F. Several independently built modules | Supported with restrictions | Modules communicate only through host types (`PatchRegistry` + host interfaces/function types). A module cannot import another module. Two modules defining the same library URI: the second is **refused safely** (`StateError: … is already loaded`); `dart2bytecode --prefix-library-uris` avoids the clash |
| Same module loaded twice | Refused safely | `StateError`, app continues |
| Incremental patch compiled against an earlier patch | Unsupported (toolchain) | `dart2bytecode` takes one `--import-dill` (the host); patches are cumulative against the store baseline |

## 3. Package renaming and import rewriting (Part 5)

| Construct | Status |
|---|---|
| Direct and transitive imports | Supported (rewritten by the analyzer-based tool) |
| `export` | Supported |
| `part` / `part of` (incl. a `.g.dart` generated file) | Supported |
| Conditional imports (`if (dart.library.io)`) | Supported |
| Circular imports inside a package | Supported |
| Several packages importing the same model | Supported (all keep the host's model) |
| Type references across package boundaries | Supported for host types; a **copied** type is a different type (§4) |
| Explicit reference to the host original next to a copy | Supported (`// pkg_rename:keep`) |
| `package:` strings outside directives, asset keys `packages/<name>/…` | Not rewritten; reported as warnings (asset keys keep pointing at the original package) |

## 4. Shared state and class identity (Part 6)

| Case | Status | Observed |
|---|---|---|
| Host object passed into a module (`User`) | Supported | Same `runtimeType`, `is`, casts, `==`/`hashCode`, field reads and writes (host AOT code sees the change), JSON round trip |
| Object created in a module from a host class | Supported | It is a host-class instance |
| `const` objects of host classes | Supported | A module `const Product(…)` is `identical` to the host's AOT `const` |
| Host enums | Supported | `identical` |
| Top-level variables, static fields, singletons, lazy `late` values of host packages | Supported | One instance, shared both ways |
| Host services: DI container, logger, config, auth/session, event bus | Supported | Module and host AOT code share one instance; events flow both ways |
| A module registers a service the host then uses | Supported | Host resolves and calls the module object |
| **Copy** of a model package (renamed `app_models`) | Unsupported for shared data | Copied `User` is not a host `User`; cast throws `TypeError` ("type 'User' is not a subtype of type 'User'"); `==` false; enums differ. Only JSON-level data matches |
| **Copy** of a state package (renamed `shared_state`) | Unsupported for shared state | A second singleton with its own state; events on the copied bus never reach the host |
| Callbacks, Futures, Streams, `async*`, exceptions (both directions), reified generics, host interface implemented in a module | Supported | All 9 checks matched expectations |

Consequence: contracts, models and state stay in the host (`REQUIRES_FULL_RELEASE` to change).

## 5. Dart language (Part 7)

49 features: each compiled, loaded and executed interpreted, with **exactly the same result as the
same source compiled AOT in the host** (differential test).

| Area | Features (all Supported) |
|---|---|
| Object-oriented | classes, abstract classes, inheritance, interfaces, mixins (`on` clause), extension methods (named/unnamed), bounded and reified generics, enhanced enums, sealed classes with exhaustive `switch` patterns, records, list/map destructuring, extension types, operator overloading |
| Constructors | default, named, **factory (cache and subtype)**, redirecting generative, **redirecting factory**, const with canonicalisation |
| Functions and state | top-level/static/instance methods, static fields, closures with captured state, higher-order functions, tear-offs, generic local functions, `late` top-level and fields (lazy, evaluated once), `Function.apply` |
| Asynchrony | `Future`, `async`/`await`, `Future.wait`, `async*`, `sync*`, `StreamController.broadcast`, async error propagation, `try/finally`, `Timer`, `Timer.periodic`, microtask ordering, zones, `Isolate.run` with an interpreted closure |
| Libraries | imports, exports, `part` files, conditional imports, annotations, JSON serialisation, `runtimeType`/`toString` |
| Values | Unicode strings, int/double edge cases, `BigInt` |

| Restricted or unsupported | Status | Observed |
|---|---|---|
| Dynamic calls (`dynamic x; x.foo()`, `jsonDecode(s)['id']`) | Unsupported (compile error by default) | The validator rejects them. With the opt-in flag `--allow-dynamic-calls-in-dynamic-modules` and a selector allow-list: calls on module classes worked; `jsonDecode(s)['id']` threw `NoSuchMethodError`; a host member listed as `dynamically-callable` worked; **a host getter not listed returned a different wrong integer on every call** (3 runs) instead of failing. Production rule: dynamic calls stay forbidden |
| `dart:mirrors` | Unsupported | Not available in Flutter at all |
| `dart:ffi` | Unsupported, **unsafe** | Compiles and passes validation, then the VM **aborts the process** (`runtime_entry.cc: unreachable code`). The generator must reject `dart:ffi` itself |

## 6. Flutter framework and UI (Part 8)

| Item | Status |
|---|---|
| Change a widget implementation, add a new widget, change `StatelessWidget`/`StatefulWidget` behaviour, `build` methods, callbacks (tap verified with `adb input tap`) | Supported |
| Change navigation logic (patched code pushes a new route; host navigates to the patched screen) | Supported |
| State-management logic, form validation, asynchronous UI (`FutureBuilder`, `StreamBuilder`) | Supported |
| Framework types from a module: `Widget`, `BuildContext`, `State`, `StateSetter`, `Navigator` (push/pop with result), `AnimationController` with `SingleTickerProviderStateMixin`, `MediaQuery`, `LayoutBuilder`, `CustomPainter`, post-frame callbacks | Supported |
| Real screen change `Product price: ₹499` → `₹399` from patched Dart code | Supported (UI dump + screenshot) |
| Changing the Flutter framework itself | Requires full release |

Requirement: the host's dynamic interface lists the Flutter `src/` libraries (callable, type,
extendable, overridable). Cost: `libapp.so` 21.7 MB instead of 5.0 MB for this app (report,
artifact sizes).

## 7. Plugins, FFI and native code (Part 9)

| Item | Status | Observed |
|---|---|---|
| Patched code calls a plugin through a host wrapper service | Supported | `KeyValueStore` → `shared_preferences` |
| Patched code calls the plugin's Dart API (host AOT) directly | Supported | Same values |
| Patched **Dart wrapper** of a plugin (renamed copy, 2.5.5 → 2.5.6) over the installed native code | Supported with restrictions | Reads and writes visible both ways; only if the platform-channel API is unchanged |
| Raw `MethodChannel` from a module to existing native code | Supported | |
| Channel without a native handler | Fails safely | `MissingPluginException` |
| Updating the **native** side (Kotlin/Java/C++/JNI), manifest, Gradle dependencies | Requires full release | No mechanism loads native code (by design) |
| FFI | Unsupported, unsafe | Process abort (§5) |

## 8. Assets (Part 10)

| Item | Status | How |
|---|---|---|
| Read existing APK assets from patched code | Supported | `rootBundle` |
| Replace an existing JSON / localisation file / image for **all** widgets that use `DefaultAssetBundle` (including `Image.asset` and unpatched AOT widgets) | Supported with restrictions | Host-owned overlay `AssetBundle` serving bytes the module carries (no engine change). Code that calls `rootBundle` directly bypasses it |
| Add a new asset | Supported with restrictions | Same overlay; the key is not in `AssetManifest` |
| Remove an asset | Unsupported | The APK cannot change; the overlay could only hide it |
| Images embedded in a module | Supported | `instantiateImageCodec` |
| Register a font at runtime | Supported | `FontLoader` |
| Fonts declared in `pubspec.yaml`, native assets | Requires full release | |

## 9. Crash recovery (Part 12)

| Scenario | Status |
|---|---|
| Valid patch starts and is confirmed | Supported |
| Module throws during initialisation | Recovered: caught, baseline runs, counted; blacklisted after 2 starts |
| Process crash before the first frame (repeated) | Recovered: counted on the next start, blacklisted after 2, baseline, no loop |
| Process crash after the first frame, before confirmation | Recovered (same) |
| Exception inside `build()` of patched code | Recovered in-process: slots fall back to AOT immediately; blacklisted after 2 starts |
| App force-stopped before confirmation | Not counted (Android `ApplicationExitInfo` reason `USER_REQUESTED`, API 30+) |
| Partially written / corrupted manifest / other runtime / other baseline patch file | Rejected before loading |
| Stored patch torn (truncated) | Detected at re-validation; baseline |
| Bytecode that passes the manifest checks but is malformed | **The VM aborts the process** (not catchable); the crash guard recovers after 2 starts. Signature/hash checks before loading are mandatory |
| Rollback, then repeated cold starts | Baseline every time |
| Device restart during activation | Not tested (would reboot the owner's phone) |

## 10. Patch sequences and baselines (Part 13)

| Sequence | Status |
|---|---|
| Patch against the store baseline | Supported |
| A then B (B replaces A; B contains everything) | Supported (cumulative) |
| Back from B to an earlier patch A of the same baseline | Supported |
| B compiled against the result of A (incremental) | Unsupported by the toolchain |
| Two packages in one patch | Supported |
| Package removed or renamed in the host | Requires full release |
| Public API of a host contract changes | Requires full release (measured: the slot ignored the copy's type) |
| Pure-Dart dependency version changes | Supported with restrictions (Scenario D) |
| Flutter version changes | Requires full release (patch for another runtime is rejected) |
| New store release installed over an active patch | See the report (old patch must be rejected: baseline id check) |

Rule: **patches are cumulative and always compiled against the original store baseline**; one
active patch per baseline; a new store build starts a new baseline with no patches.
