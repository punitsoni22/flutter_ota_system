# flutter_ota_system

The Flutter SDK of **[Flutter OTA System](https://github.com/punitsoni22/flutter_ota_system)**, an open-source, **self-hosted** over-the-air (OTA) update platform for Flutter apps. Your servers, your signing keys, your control.

> [!WARNING]
> **Experimental alpha. Not production-ready.**
> - Android only. The bytecode runtime is **Android arm64 only**, with the Flutter OTA custom engine (Flutter 3.47.9 or 3.50.0), and was tested end to end on **one Android 13 arm64 phone**.
> - Apps are built on **Linux x64** machines with the `flutter_ota` CLI.
> - iOS, macOS, Windows, Linux and web apps are not supported.
> - No independent security audit, and no app-store approval of any kind.

Read first:
- [compatibility and limitations](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/limitations.md);
- [security](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/security.md);
- [Google Play policy notes](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/policy/google-play.md);
- [privacy and data handling](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/privacy-and-data-handling.md).

## What it does

The package contains two independent runtimes. **Use one per app.**

| Runtime | API | Status |
| --- | --- | --- |
| **Bytecode runtime** (new in `0.2.0-alpha`) | `FlutterOta`, `OtaFeature` | Experimental. Patched feature code runs as Dart bytecode in the custom engine's interpreter. The store `libapp.so` is never replaced |
| **Original alpha runtime** (`0.1.0-alpha.1`) | `OtaClient`, `OtaConfig`, `AotPatchRuntime`, `MockPatchRuntime` | Experimental. Server-signed patches; Android code patches replace `libapp.so` (binary diff). Stock Flutter 3.44.9+ |

## Install

In your Flutter project folder:

```bash
flutter pub add flutter_ota_system
```

The bytecode runtime also needs the [`flutter_ota_cli`](https://pub.dev/packages/flutter_ota_cli) tool (`dart pub global activate flutter_ota_cli`). It downloads the custom toolchain, and builds and signs everything on your machine. See the [quick start](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/quick-start.md).

## Bytecode runtime

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterOta.initialize();
  runApp(const MyApp());
}
```

Patchable code lives in **feature packages**. Each has one entry class:

```dart
class ProductsFeature extends OtaFeature {
  @override
  Widget build(BuildContext context, [Object? arguments]) => const ProductsScreen();
}
```

The app shows features through the registry that `flutter_ota release android` generates: `OtaFeatures.products.build(context)`.

**What `initialize()` does:**
- **It never throws, and makes no network request at start.** It verifies the stored patch (signature, certificate, release, toolchain, hashes, revocations), loads it and returns.
- **It confirms the start and checks for updates.** After the first frame it confirms the start, then checks for a new patch in the background.
- **New patches are tested first.** A new patch is test-loaded in a separate process, then runs from the next start.
- **Crashes trigger rollback.** A patch that crashes the app is rolled back automatically.
- **It is off without the CLI's build config.** Without the build configuration from the CLI (for example a plain `flutter run`), OTA is off and the store code runs.

Full reference: [Flutter integration](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/flutter-integration.md) · [feature patching](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/feature-patching.md).

## Original alpha runtime

```dart
final client = OtaClient(OtaConfig(
  serverUrl: 'https://ota.example.com',
  appSlug: 'my-app',
  applicationId: '<server app UUID>',
  releaseVersion: '1.0.0+1',
  publicKeys: {'prod-1': '<public key from `ota key show`>'},
  runtime: AotPatchRuntime(),           // or MockPatchRuntime() for config-only test patches
));
await client.boot();                     // never throws
client.markBootSuccessfulAfterFirstFrame();
await client.checkForUpdate();           // never throws; returns an UpdateResult
```

The server signs these patches; the app trusts the public keys you compile in. `AotPatchRuntime` loads a downloaded native `libapp.so`, which has significant store-policy implications. See [releases and patches](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/releases-and-patches.md#original-alpha-patch-formats).

## Requirements

| | Bytecode runtime | Original alpha runtime |
| --- | --- | --- |
| Flutter | 3.47.9 (Dart 3.13) or 3.50.0 (Dart 3.14) for `flutter pub` and your IDE, the same version your project's toolchain pins; the app is built with that version and the Flutter OTA custom engine (downloaded by `flutter_ota`) | 3.44.9 or newer |
| Platform | Android arm64 | Android |
| Developer machine | Linux x64 | Linux (the only tested host) |
| Server | A self-hosted Flutter OTA System server | Same |
| Network | `https://` in release builds (`http://` only to loopback, for local testing) | `https://` in release builds |

## Development

From `packages/ota_client` in the repository:

```bash
flutter pub get && flutter analyze && flutter test
```

The tests cover both runtimes, including the ported patch-security tests.

The Android code has JVM unit tests (`android/src/test`). To run them through the example app (JDK 17+):

```bash
cd example && flutter build apk --config-only
cd android && ./gradlew :flutter_ota_system:testDebugUnitTest
```

## Links and licence

- Repository: <https://github.com/punitsoni22/flutter_ota_system>
- Issues: <https://github.com/punitsoni22/flutter_ota_system/issues>
- Security reports: see [SECURITY.md](https://github.com/punitsoni22/flutter_ota_system/blob/main/SECURITY.md)

Apache License 2.0, Copyright The Punit Authors. Contains an implementation of the bspatch algorithm by Colin Percival (BSD-2-Clause); see `lib/src/bsdiff.dart` and [THIRD_PARTY_NOTICES.md](https://github.com/punitsoni22/flutter_ota_system/blob/main/THIRD_PARTY_NOTICES.md).
