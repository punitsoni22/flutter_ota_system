<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Feature patching (`flutter_ota features`, `flutter_ota patch android`)

Status: experimental alpha. Android arm64 apps, Linux x64 developer machines only. Tested end to
end on one Android 13 phone with the [demo app](../packages/ota_client/example/README.md): an API
endpoint change, a new freezed model field (regenerated `.freezed.dart` / `.g.dart`), entity,
repository and UI changes, shipped with one `flutter_ota patch android`.

## 1. The idea

A patch can only change code in **feature packages**. A feature package is a normal local Dart
package inside your project, for example `packages/products/`. Your app reaches each feature
through one generated getter, `OtaFeatures.products`. When a verified patch provides a new version
of `products`, that getter returns the new code; otherwise it returns the code in the store build.

You do not write config files, rename packages or write slots by hand. The CLI finds the features
from your package graph.

**What a patch can change** (inside feature packages): API calls and parsing logic, feature-owned
models (including freezed and json_serializable generated code), entities, repositories,
controllers and state classes, widgets and UI. **What it cannot change** is listed in
[section 6](#6-what-needs-a-new-store-release): the app package, shared packages, dependencies,
native code and assets.

Patching arbitrary code without feature packages (a whole-app patch) is **not supported**. It is a
research topic: it compiles in experiments but has not been validated on a device.

## 2. Project layout

```text
my_app/
  flutter_ota.yaml            app_id only
  pubspec.yaml                depends on flutter_ota_system, core, products, ...
  lib/main.dart               await FlutterOta.initialize(); then runApp(...)
  lib/flutter_ota_features.g.dart   generated: one getter per feature
  packages/
    core/                     SHARED: contracts, shared models, shared state
    products/                 FEATURE: lib/products.dart declares ProductsFeature
    products_data/            FEATURE-INTERNAL: used only by products
```

## 3. The rules (conventions)

1. **Local packages** are the path dependencies (and pub workspace members) whose folder is
   inside the project folder. Path dependencies outside the project are treated as shared.
2. **A feature** is a local package whose main library `lib/<package>.dart` declares (or exports)
   a public class named `<PascalCase(package)>Feature`:
   - `products` -> `ProductsFeature`, `user_profile` -> `UserProfileFeature`;
   - `feature_cart` may also use `CartFeature`; `cart_feature` may use `CartFeature`.

   The class must not be abstract, must have no type parameters, and must have an unnamed
   constructor without required arguments (the registry calls `ProductsFeature()`).
3. **Contract type.** A patch contains *renamed copies* of feature packages, so the feature's own
   class is a different type inside a patch. The entry class must therefore extend or implement a
   **host-owned** type, and the registry uses that type:
   - the SDK's `OtaFeature` (zero boilerplate: `class ProductsFeature extends OtaFeature`), or
   - an abstract class from a shared package (`class CartFeature implements CartApi`, with
     `CartApi` in `packages/core`).

   The CLI picks the **nearest** host-owned supertype. It also looks through base classes inside
   the feature (`CartFeature extends CartBase`, `CartBase implements CartApi` -> `CartApi`). If
   there is none, `flutter_ota features` shows a problem and nothing is generated.
4. **Feature-internal** packages are used by exactly one feature and by nothing else. They are
   patched together with that feature.
5. **Shared (host-owned)** packages are everything else:
   - used by the app's own code (`lib/`), or by another shared package;
   - used by two or more features;
   - used by no feature at all.

   A feature that the app imports directly (outside the generated file), or that a shared
   package depends on, is also treated as shared, with a warning. Use `OtaFeatures.<name>`
   instead of importing the feature.
6. The **app package** itself is never patchable.
7. Packages that belong to flutter_ota itself are always host-owned: the `dynamic_modules`
   loader package (the release command copies it into `.flutter_ota/packages/dynamic_modules`)
   and anything else under `.flutter_ota/`. They are never features and are never patched or
   renamed.

See your graph at any time:

```bash
flutter_ota features          # readable graph, warnings and problems
flutter_ota features --json   # the same as JSON
```

## 4. The generated registry

```bash
flutter_ota features generate           # writes lib/flutter_ota_features.g.dart
flutter_ota features generate --check   # exit 1 if it is out of date (for CI)
```

The release command owns `lib/flutter_ota_main.g.dart` (see below) and creates it. If that file
exists, `features generate` re-renders it with the same code the release command uses, and
`--check` reports it when it differs (for example after a hand edit).

`flutter_ota release android` regenerates it before every store build. Example output:

```dart
// generated by flutter_ota (4F) in the app: lib/flutter_ota_features.g.dart
// Do not edit by hand. Regenerate with: flutter_ota features generate
import 'package:flutter_ota_system/flutter_ota_system.dart';
import 'package:core/core.dart' as contract_core;
import 'package:cart/cart.dart' as feature_cart;
import 'package:products/products.dart' as feature_products;
abstract final class OtaFeatures {
  static contract_core.CartApi get cart =>
      FlutterOta.feature<contract_core.CartApi>('cart', () => feature_cart.CartFeature());

  static OtaFeature get products =>
      FlutterOta.feature<OtaFeature>('products', () => feature_products.ProductsFeature());
}
```

Imports always use the prefixes `feature_<package>` and `contract_<package>`, never the plain
package name, because a getter with the same name would hide the prefix.

The registry does not register the patch module loader. The release command generates
`lib/flutter_ota_main.g.dart` for that and builds with it, so your `main.dart` stays
`await FlutterOta.initialize();`.

## 5. Making a patch

```bash
flutter_ota patch android --dry-run                    # build, check and sign locally; no upload
flutter_ota patch android                              # upload as a draft patch
flutter_ota patch android --channel beta --rollout 10  # upload and publish to 10% of "beta"
flutter_ota patch android --release <release-uuid>     # a specific release (default: the newest)
```

Uploading needs the server URL (`flutter_ota config set server-url ...`) and the admin key in
the environment variable `FLUTTER_OTA_ADMIN_KEY` (never saved in a file).

What the command does:

1. Reads the release baseline in `.flutter_ota/releases/<release_id>/` (written by
   `flutter_ota release android`) and checks it was built with the toolchain this project pins.
2. Runs `flutter pub get` with the toolchain SDK and compares the project with the release's
   `feature_snapshot.json`. **Patches are cumulative**: each patch carries every change since
   the store release, not only the change since the last patch.
3. **Closure rule:** the patch contains each changed feature or feature-internal package, plus
   every feature or feature-internal package that depends on one of them. Otherwise an unchanged
   package would keep calling the old code.
4. **Generated code check:** for each changed package that uses `build_runner`, the CLI copies
   the project to a temporary folder, runs
   `dart run build_runner build --delete-conflicting-outputs` there, and compares every file in
   `lib/`. If a generated file differs, the patch is refused with the command to run. Your
   project is never changed. A successful check is cached until the inputs change.
5. Copies and renames the patched packages (`products` -> `products_ota<sequence>`), generates
   the module entry (contract 3: slot name -> factory), and checks it with `patch_guard`:
   compile errors, FFI, `dart:mirrors`, internal `dart:_` libraries, dynamic calls,
   `noSuchMethod`, and dependencies that are not part of the store build are rejected.
6. Compiles with `dart2bytecode` against the release's `link.dill` and dynamic interface, then
   runs the reference bytecode verifier (`bc_verify`, from the toolchain's `tools/bc_verify.aot`).
   A patch is never uploaded without it.
7. Builds the manifest (format 2, entry contract 3, toolchain record, baseline `libapp.so`
   SHA-256, release id, next sequence, new patch id), signs it with your certified signer key
   (see [security](security.md#developer-owned-signing)), checks the signed file again, and writes
   `.flutter_ota/releases/<release_id>/patches/<sequence>/patch.otp` and `patch.json`.
8. Uploads it (`dbc-v1`) and optionally publishes it. Without `--channel` it stays a draft.

A patch is **never uploaded** if it is not signed or the reference verifier did not run.

All builds run below the canonical build root (`/tmp/flutter_ota-build`, or
`FLUTTER_OTA_BUILD_ROOT`; use the same value as for the release), so the patch contains no path
from your home folder.

## 6. What needs a new store release

The command refuses, with the exact reason, when any of these changed since the release:

| Change | Why |
| --- | --- |
| the app package (`lib/`, assets, android/...) | compiled into the store build; never patchable |
| a shared package | its types and state belong to the store build; a copy would be a different package |
| `pubspec.lock` | the store build used other dependency versions |
| `lib/flutter_ota_features.g.dart` | features added, removed or renamed: the store build has other slots |
| native code (`android/`, `ios/`, `src/`, ...) in a package | only Dart code can be patched |
| assets, fonts or the pubspec `flutter:` section of a feature | patches carry no assets yet |
| a new dependency that is not in the store build | it is not in `link.dill` |
| a new or removed local package | not in the store build |
| a feature's entry class or contract type | the slot of the store build would not match |
| another toolchain pinned in `flutter_ota.lock` | patches only fit the exact toolchain |
| freezed older than 4.0.3 | Dart 3.13 rejects its generated code |

## 7. freezed and json_serializable

- Use freezed 4.0.3 or newer. Recommended: `explicit_to_json: true` in `build.yaml`.
- Recommended: let the app depend on `freezed_annotation` and `json_annotation` directly, so they
  are part of the store build (as the demo app does).
- If `dart2bytecode` fails with `Cannot extend ... in a dynamic module` (for example
  freezed's `EqualUnmodifiableSetView`), a class the patch extends is not allowed by the store
  build's dynamic interface. Making the app depend on the annotation packages directly (above)
  avoids this case.
- Always re-run `build_runner` after changing models; the patch command checks it.

## 8. Known limits

- Discovery reads Dart sources with a small built-in reader, not the full analyzer. Everything it
  finds is checked again by the real compilers (the store build, `patch_guard`, `dart2bytecode`).
- Toolchains installed before `bc_verify` was bundled have no `tools/bc_verify.aot`. With those,
  upload is refused; install a newer toolchain, or use `--dry-run`. (Toolchain builders only:
  `FLUTTER_OTA_BC_VERIFY=<path to a bc_verify AOT snapshot>` is used when the toolchain has none.)
- Approvals (extra approver signatures) are not added by this command yet.
- Tested on one phone and one small demo app. Large apps, many features and other devices are
  not tested yet. Patched code runs in the bytecode interpreter: CPU-heavy code is slower than in
  the store build.
