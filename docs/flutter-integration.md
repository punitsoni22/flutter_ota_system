# Flutter integration (SDK reference)

How an app uses the `flutter_ota_system` package. The setup steps are in the [quick start](quick-start.md).

**Status: experimental alpha.**
- Supports Android arm64, with the Flutter OTA toolchain (Flutter 3.47.9 plus our custom engine).
- The bytecode runtime was tested on one Android 13 phone.
- A normal Flutter SDK cannot load patches.

## The code you write once

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterOta.initialize();
  runApp(const MyApp());
}
```

`FlutterOta.initialize({stablePeriod = 10 s, checkForUpdates = true})` behaves like this:
- **It never throws.** If anything goes wrong, the store code runs and a log line says why.
- **It makes no network request on the start-up path.** It verifies the patch already on the phone, loads it and returns.
- **It confirms the start.** After the first frame plus the stable period, it confirms that the app started well.
- **It checks for updates in the background.** After that, it checks the server for a new patch.

**Feature entry class.** Each feature package has one entry class that extends `OtaFeature`:

```dart
// packages/products/lib/products.dart
class ProductsFeature extends OtaFeature {
  @override
  Widget build(BuildContext context, [Object? arguments]) => const ProductsScreen();
}
```

## The code the CLI writes for you

`flutter_ota release android` generates these files. Commit them, but don't edit them.

**`lib/flutter_ota_features.g.dart`** has one getter per feature. Use it as `OtaFeatures.products.build(context)`:

```dart
abstract final class OtaFeatures {
  static OtaFeature get products =>
      FlutterOta.feature<OtaFeature>('products', () => feature_products.ProductsFeature());
}
```

**`lib/flutter_ota_main.g.dart`** is the file the app is built from. It registers the patch loader, then calls your `main()`, so `main.dart` needs nothing extra.

**`FlutterOta.feature<T>(name, aotFactory)`:**
- returns the patch's version of the feature when the active patch has it **and** it is a `T`;
- otherwise returns `aotFactory()`, the code from the store build;
- **never crashes**: a wrong type is ignored and logged once.

`T` must be **host-owned**: `OtaFeature`, or an abstract class from a shared package. A patch carries a *renamed copy* of the feature, so the feature's own class is a different type inside a patch. The full contract is in [architecture/runtime-contract.md](architecture/runtime-contract.md).

## Configuration

The CLI passes one value at build time: `--dart-define=FLUTTER_OTA_CONFIG=<base64url canonical JSON>`.

**What it contains:** only public values:
- app id and server URL;
- release id and release version;
- environment;
- the **public** root keys;
- the toolchain identity.

There is never a private key in it.

**Without it, OTA is off.** For example, after a plain `flutter run` the app runs normally, and the log says:

```text
[flutter_ota] DISABLED FLUTTER_OTA_CONFIG is not set (for example a plain `flutter run`); the store code runs
```

## What happens to a new patch

1. **Check.** The background check asks the server for `dbc-v1` patches for this exact release.
2. **Download.** The SDK downloads the patch file (`OTAPRT02`) and checks its size and SHA-256.
3. **Verify.** It checks:
   - the signature, by a key your root key certified;
   - app, release and the store `libapp.so` hash;
   - toolchain, runtime and interface;
   - signed revocation lists;
   - replay (sequence number) and expiry.
4. **Test-load.** It loads the patch once in a **separate process** (`:flutter_ota_verify`). The engine's bytecode verifier checks every function there. If that process refuses the patch or crashes, the patch is never used.
5. **Store.** The patch is stored and runs from the **next app start**. Running code is never swapped live.
6. **Re-check.** At every start, the stored patch is verified again before it loads.
7. **Crash recovery.** A patch that crashes the app twice is rolled back and blocklisted. The last confirmed patch, or the store code, runs instead. Force-stops and low-memory kills are not counted as crashes.

## Useful getters

| API | Meaning |
| --- | --- |
| `FlutterOta.status` | `notInitialized`, `disabled`, `storeCode` or `patched` |
| `FlutterOta.isEnabled` / `disabledReason` | Whether OTA runs in this start, and why not |
| `FlutterOta.activePatch` / `activePatchId` | The patch running now, or `null` |
| `FlutterOta.pendingPatchId` | A verified patch that runs after the next restart |
| `FlutterOta.lastStartupTimings` | How long `initialize()` took, in parts |
| `FlutterOta.checkForUpdate()` | Check now. Never throws; returns an `UpdateResult` |

## Logs

All lines start with `[flutter_ota]` and appear in `adb logcat` (tag `flutter`). This is from the real-device test:

```text
[flutter_ota] STATE patch=1776f9f9 - -> DOWNLOADED (authentic: signature, hashes and compatibility verified)
[flutter_ota] VERIFY_PROCESS status=OK (295 ms): products=ProductsFeature
[flutter_ota] STAGED patch #2 1776f9f9 (23308 bytes): restart required
[flutter_ota] ACTIVATED patch #2 1776f9f9
[flutter_ota] LOADED patch #2 1776f9f9 features=products in 3.8 ms
[flutter_ota] STATE patch=1776f9f9 PROBATIONARY -> ACTIVE (health check passed)
```

## Local testing with a server on your computer

Release builds only talk to `https://` servers, with one exception: plain `http://` is allowed for loopback addresses (`127.0.0.1`, `localhost`, `[::1]`). Forward the phone's port to your computer:

```bash
adb reverse tcp:8000 tcp:8000
flutter_ota config set server-url http://127.0.0.1:8000
```

Other `http://` hosts, such as a LAN address, are always refused in release builds.

## Original alpha API (`OtaClient`)

The `v0.1.0-alpha.1` API is unchanged:
- `OtaClient`, `OtaConfig`, `AotPatchRuntime`, `MockPatchRuntime`;
- server-signed `aot-bidiff-android-v1` patches that replace `libapp.so`;
- works on stock Flutter 3.44.9+.

It is separate from the bytecode runtime. **Don't use both in one app.**

```dart
final client = OtaClient(OtaConfig(
  serverUrl: 'https://ota.example.com',
  appSlug: 'my-app',
  applicationId: '<server app UUID>',
  releaseVersion: '1.0.0+1',
  publicKeys: {'prod-1': '<public key from `ota key show`>'},
  runtime: AotPatchRuntime(),
));
await client.boot();
client.markBootSuccessfulAfterFirstFrame();
await client.checkForUpdate();
```

See [releases and patches](releases-and-patches.md#original-alpha-patch-formats) and the [Google Play policy notes](policy/google-play.md). Replacing executable code has policy implications.
