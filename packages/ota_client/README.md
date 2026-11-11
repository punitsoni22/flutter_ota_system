# ota_client

The Flutter client of [Flutter OTA System](../../README.md), an experimental, self-hosted over-the-air (OTA)
patch system. It checks a Flutter OTA System server for patches, verifies them (ES256 signature, size,
SHA-256), stages them, activates them on the next app start, and falls back automatically when a
new patch fails to start.

> **Experimental (v0.1.0-alpha.1).** Tested internally only, on **Android** (a small number of
> devices). **iOS is not tested**; iOS code patches are not implemented, and the pure-Dart
> `mock-v1` runtime has not been tried on iOS. Android Dart code patches (`AotPatchRuntime`) are
> experimental. Android testing does not establish compatibility with every Android device, OS
> version, ABI or Flutter version. Not published on pub.dev. See the
> [testing status](../../README.md#platform-support--testing-status).

## Use it

```yaml
dependencies:
  ota_client:
    git:
      url: https://github.com/punitsoni22/flutter_ota_system.git
      path: packages/ota_client
```

```dart
final client = OtaClient(OtaConfig(
  serverUrl: 'https://ota.example.com',
  appSlug: 'my-app',
  releaseVersion: '1.0.0+1',                 // full version, exactly as registered
  publicKeys: {'prod-1': '<base64 point>'},  // from `ota key show`
  runtime: AotPatchRuntime(),                // or MockPatchRuntime() for config patches
));
await client.boot();
client.markBootSuccessfulAfterFirstFrame();
final result = await client.checkForUpdate(); // UpdateResult; never throws
```

Adding this package alone does not make compiled Dart code patchable: see the requirements in the
[Flutter integration guide](../../docs/flutter-integration.md).

## Main types

| Type | Purpose |
|---|---|
| `OtaClient`, `OtaConfig` | The client and its settings |
| `PatchRuntime` | How a patch runs. Implementations: `MockPatchRuntime` (`mock-v1`), `AotPatchRuntime` (`aot-bidiff-android-v1`, Android) |
| `UpdateResult`, `UpdateStatus` | Result of a check |
| `PatchRecord` | A patch offered by the server |
| `SignatureVerifier`, `SignedFields` | ES256 verification of the canonical patch message |

## Requirements

Dart ≥ 3.12, Flutter ≥ 3.27 (tests ran with Flutter 3.44 stable). Android: `minSdk` 21, Java 17. The plugin registers
`OtaBootProvider` in its Android manifest; no `MainActivity` changes are needed.

## Tests

```bash
flutter pub get && flutter analyze && flutter test
```

The Android code has JVM unit tests (`android/src/test`). They are not run in CI; run them
locally through the example app, which hosts the plugin (needs JDK 17 or newer):

```bash
cd ../../example_app
flutter build apk --config-only          # creates android/gradlew and local.properties
cd android && ./gradlew :ota_client:testDebugUnitTest
```

## Licence

Apache License 2.0. Contains an implementation of the bspatch algorithm by Colin Percival
(BSD-2-Clause); see `lib/src/bsdiff.dart` and the repository's
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
