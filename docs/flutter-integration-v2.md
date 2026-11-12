<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Flutter integration v2: the bytecode runtime (`FlutterOta`)

Status: **experimental alpha** (Phase 4, milestone 4C). Android arm64 only. Tested on Linux in
unit tests only; device tests follow in milestone 4I. Not production-ready.

This guide explains how an app uses the new runtime of the `flutter_ota_system` package. The older
API (`OtaClient`, see [flutter-integration.md](flutter-integration.md)) still works and is
unchanged.

## 1. What you need

- The **Flutter OTA System toolchain** (Flutter 3.47.9 with our engine). The `flutter_ota` CLI
  installs and uses it for you. A normal Flutter SDK cannot load patches.
- Your features as **local packages** (for example `packages/products/`), and a shared package for
  models used by several features (see the [runtime contract](architecture/phase-4-runtime-contract.md)).
- A self-hosted Flutter OTA System server.

## 2. The code you write (once)

`lib/main.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterOta.initialize();
  runApp(const MyApp());
}
```

That is all. Things to know about `initialize()`:

- It **never throws**. If anything goes wrong, your normal (store) code runs and a log line says why.
- It makes **no network request**. It checks the patch that is already on the phone, loads it, and
  returns.
- After the first frame and a **stable period** (10 seconds by default) it confirms that the app
  started well. Then it checks the server for a new patch **in the background**.

Each feature package has an entry class that extends `OtaFeature` (from this SDK):

```dart
// packages/products/lib/products.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

class ProductsFeature extends OtaFeature {
  @override
  Widget build(BuildContext context, [Object? arguments]) => const ProductsScreen();
}
```

## 3. The code the CLI writes for you

You do not edit these files. The CLI generates them.

`lib/flutter_ota_features.g.dart` gives you one getter per feature:

```dart
abstract final class OtaFeatures {
  static OtaFeature get products =>
      FlutterOta.feature<OtaFeature>('products', () => products.ProductsFeature());
}
```

Use it in your widgets: `OtaFeatures.products.build(context)`.

`FlutterOta.feature<T>(name, aotFactory)`:

- returns the patch's version of the feature when the active patch has it **and** it is a `T`;
- otherwise returns `aotFactory()` (the code from the store build);
- never crashes. A wrong type is ignored and logged once.

`T` must be **host-owned**: `OtaFeature`, or an abstract class from a shared package. Never use
the feature's own class as `T`. A patch carries a *renamed copy* of the feature, so its class is a
different type, and the store code would always be used.

`lib/flutter_ota_main.g.dart` is the file the CLI builds your app from (`-t`). It registers the
module loader and then calls your `main()`. That is why your `main.dart` needs no extra line.
Details: [phase-4-sdk-runtime.md](architecture/phase-4-sdk-runtime.md), section 3.

## 4. Configuration

The CLI passes one value at build time:

```text
--dart-define=FLUTTER_OTA_CONFIG=<base64url of canonical JSON>
```

It holds only public values: the app id, server URL, release id, **public** root keys and the
toolchain identity. There is never a private key in it.

Without this value (for example a plain `flutter run`), OTA is **off**: the app runs normally and
the log says:

```text
[flutter_ota] DISABLED FLUTTER_OTA_CONFIG is not set (for example a plain `flutter run`); the store code runs
```

## 5. What happens to a new patch

1. The background check calls `GET /v1/updates/check` with `supported_formats=dbc-v1`.
2. The SDK downloads the patch (an `OTAPRT02` file) and checks its size and SHA-256.
3. It verifies the patch: signature by a key that your **root key** certified, app, release,
   `libapp.so` hash, toolchain, runtime, interface, revocations, replay and expiry.
4. It loads the patch **once in a separate process** (`:flutter_ota_verify`). If that process
   crashes or refuses the patch, the patch is never used.
5. It stores the patch. It runs from the **next app start**. Running code is never swapped live.
6. At every start the stored patch is verified again before it is loaded.

If a new patch crashes the app twice before it is confirmed (or after), it is rolled back
automatically and never tried again. The last confirmed patch, or the store code, runs instead.

## 6. Useful getters

| Getter | Meaning |
| --- | --- |
| `FlutterOta.status` | `notInitialized`, `disabled`, `storeCode` or `patched` |
| `FlutterOta.isEnabled` | OTA runs in this start |
| `FlutterOta.disabledReason` | why OTA is off, or `null` |
| `FlutterOta.activePatch` / `activePatchId` | the patch running now, or `null` |
| `FlutterOta.pendingPatchId` | a verified patch that runs after the next restart |
| `FlutterOta.lastStartupTimings` | how long `initialize()` took, in parts |
| `FlutterOta.checkForUpdate()` | check now (never throws), returns an `UpdateResult` |

## 7. Logs

All lines start with `[flutter_ota]` and appear in `adb logcat` (tag `flutter`). Examples:

```text
[flutter_ota] STATE patch=1a2b3c4d VERIFIED -> PROBATIONARY (activated; waiting for a confirmed start)
[flutter_ota] LOADED patch #2 1a2b3c4d features=products in 41.3 ms
[flutter_ota] STARTUP total_ms=63.0 native_ms=4.1 libapp_hash_ms=0.9 verify_ms=12.2 module_load_ms=41.3
[flutter_ota] CONFIRMED patch=1a2b3c4d start confirmed
```

## 8. Local testing with a server on your computer

Release builds only talk to `https://` servers. For local tests there is one exception: plain
`http://` is allowed to **loopback** addresses (`127.0.0.1`, `localhost`, `[::1]`). Forward the
phone's port to your computer:

```bash
adb reverse tcp:8000 tcp:8000
```

Then build with a server URL like `http://127.0.0.1:8000`. Other `http://` hosts (for example a
LAN address) are always refused in release builds.

## 9. Known limits

- Android arm64 only, with the pinned toolchain.
- The verifier process has the same Linux user as the app. It is a separate process, **not** a
  sandbox (Flutter cannot start in an Android isolated process in release builds).
- Patches can change code inside feature packages only. Shared models and the app package
  itself need a store release.
- Device tests of this runtime are part of milestone 4I.
