# Flutter integration guide

How to connect a Flutter app to your Punit server with the `ota_client` package. You need a
running server first ([installation.md](installation.md)) and should know the
[core concepts](concepts.md).

> [!IMPORTANT]
> **Adding the package does not, by itself, make your compiled Dart code patchable.** Android code
> patches work only when **all** of these are true:
>
> 1. the app uses `AotPatchRuntime` (not `MockPatchRuntime`);
> 2. it runs on **Android**, as a **release** build (debug builds run Dart in JIT mode and ignore
>    code patches);
> 3. the installed APK/AAB is **exactly** the build that `ota release android` registered;
> 4. the patch was built with the **same Flutter version**, and changes **only Dart code**.
>
> Android code patches are **experimental** (tested internally on a small number of devices).
> **iOS code patches are not supported.**

## Choose a runtime

| Runtime | Format | What a patch can do | Platforms |
|---|---|---|---|
| `MockPatchRuntime` | `mock-v1` | Deliver an inert file (e.g. JSON config) that your app reads at start. No code runs | Pure Dart. Tested on Android; **not tested on iOS** |
| `AotPatchRuntime` | `aot-bidiff-android-v1` | Replace the app's compiled Dart code | Android release builds only. 🟡 Experimental |

No custom Flutter engine is needed: `AotPatchRuntime` uses stock Flutter's ability to load
`libapp.so` from a file path ([architecture.md](architecture.md#patch-engine-and-flutter-integration-android-code-patches)).

## 1. Add the dependencies

`pubspec.yaml`:

```yaml
dependencies:
  package_info_plus: any            # to read the app's version; skip if you already have it
  ota_client:
    git:
      url: https://github.com/punitsoni22/flutter_ota_system.git
      path: packages/ota_client
      ref: main                     # or a release tag
```

Then run `flutter pub get`. With a local copy of the repository you can use
`path: ../flutter_ota_system/packages/ota_client` instead. `ota_client` is not published on
pub.dev.

Requirements: Dart ≥ 3.12, Flutter ≥ 3.27. The Android part needs `minSdk` 21 or higher and
Java 17. It adds no permissions; your app needs `INTERNET`, which almost every app has.

**No native changes are required.** The plugin's Android manifest registers `OtaBootProvider`,
and Android's manifest merger adds it to your app. You do not edit `MainActivity`.

## 2. Register the app and get the public key

On the server (once per app), with the [CLI](cli-reference.md):

```bash
ota app create shop-app "Shop" --distribution public_store   # or enterprise (default)
ota key show
```

`ota key show` prints the public key:

```json
{
  "key_id": "prod-1",
  "algorithm": "ES256",
  "uncompressed_point_base64": "BIi7De…",
  "pem": "-----BEGIN PUBLIC KEY-----\n…"
}
```

The app needs `key_id` and `uncompressed_point_base64`. `ota key show --dart` prints them as a
Dart constant: `const otaPublicKeys = {'prod-1': 'BIi7De…'};`.

The app **only** trusts the keys you compile into it. Never ship an app that trusts a local
development key (`local-dev-1`).

## 3. Create the client

The configuration object is `OtaConfig`
([`ota_client.dart`](../packages/ota_client/lib/src/ota_client.dart)):

| Field | Required | Meaning |
|---|---|---|
| `serverUrl` | yes | Your server, e.g. `https://ota.example.com` |
| `appSlug` | yes | The application slug on the server |
| `releaseVersion` | yes | The **full** store version, exactly as registered: `'${info.version}+${info.buildNumber}'` |
| `publicKeys` | yes | `{key_id: base64 point}`. Several keys are allowed (for key rotation) |
| `runtime` | yes | `AotPatchRuntime()` or `MockPatchRuntime()` |
| `channel` | no | Default channel of this build. Default `production` |
| `applicationId` | no | Pin the server's application id; responses for another app are refused |
| `storageDir`, `platform`, `arch`, `httpClient` | no | Test overrides. Defaults: app support directory, current platform, current CPU ABI |

### Code patches (Android): a ready-made helper

This helper is the integration used for code patches in practice. Create `lib/ota_updater.dart`
and set `_appSlug`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ota_client/ota_client.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Build-time settings (`--dart-define`):
///   OTA_SERVER_URL  the Punit server. Empty = OTA off.
///   OTA_PUBLIC_KEY  "key_id:base64_point" from `ota key show`. Patches are refused without it.
///   OTA_CHANNEL     default channel of this build (production).
class OtaUpdater {
  OtaUpdater._();

  static const _serverUrl = String.fromEnvironment('OTA_SERVER_URL');
  static const _publicKey = String.fromEnvironment('OTA_PUBLIC_KEY');
  static const _channel = String.fromEnvironment('OTA_CHANNEL', defaultValue: 'production');
  static const _appSlug = 'shop-app'; // ← your app's slug

  static OtaClient? _client;

  /// The patch running now (null = the store build), once [start] has run.
  static PatchRecord? get activePatch => _client?.activePatch;
  static String get channel => _client?.channel ?? _channel;

  static Future<void> start() async {
    if (_serverUrl.isEmpty || _client != null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      final key = _publicKey.split(':');
      final client = OtaClient(OtaConfig(
        serverUrl: _serverUrl,
        appSlug: _appSlug,
        channel: _channel,
        releaseVersion: '${info.version}+${info.buildNumber}',
        publicKeys: key.length == 2 ? {key[0]: key[1]} : const {},
        runtime: AotPatchRuntime(),
      ));
      await client.boot();
      _client = client;
      client.markBootSuccessfulAfterFirstFrame(stableFor: const Duration(seconds: 5));
      final result = await client.checkForUpdate();
      debugPrint('OTA: running patch ${client.activePatchNumber}, check: $result');
    } catch (e, st) {
      debugPrint('OTA: start failed: $e\n$st');
    }
  }

  /// Testers: "staging" gets patches before production. Null = back to this build's default.
  static Future<UpdateResult?> setChannel(String? channel) async {
    final client = _client;
    if (client == null) return null;
    await client.setChannel(channel);
    return client.checkForUpdate(force: true);
  }

  static Future<UpdateResult?> checkNow() async => _client?.checkForUpdate(force: true);
}
```

Start it in `main.dart`, **after** the first frame:

```dart
import 'ota_updater.dart';

void main() {
  runApp(const MyApp());
  WidgetsBinding.instance.addPostFrameCallback((_) => OtaUpdater.start());
}
```

For code patches, which code runs is decided natively **before** Dart starts, so starting the
client after the first frame never delays startup.

### Config patches (`mock-v1`): read the payload at start

With `MockPatchRuntime`, call `boot()` **before** `runApp`, because the app reads the active
payload while it builds its first screen. From [`example_app/lib/main.dart`](../example_app/lib/main.dart):

```dart
final _runtime = MockPatchRuntime();
late final OtaClient ota;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final info = await PackageInfo.fromPlatform();
  final keyParts = _publicKey.split(':');

  ota = OtaClient(OtaConfig(
    serverUrl: _serverUrl,
    appSlug: _appSlug,
    channel: _channel,
    releaseVersion: '${info.version}+${info.buildNumber}',
    publicKeys: keyParts.length == 2 ? {keyParts[0]: keyParts[1]} : const {},
    runtime: _runtime,
  ));
  await ota.boot();

  final config = _patchConfig();           // reads _runtime.activePayload (bytes or null)
  runApp(DemoApp(config: config));
  ota.markBootSuccessfulAfterFirstFrame(stableFor: const Duration(seconds: 5));
  ota.checkForUpdate();                    // background, never blocks startup
}
```

`MockPatchRuntime.activePayload` is the active patch's bytes, or `null` for the store build. The
payload hash is re-checked from disk on every start.

## 4. What the client does

| Call | When | What happens |
|---|---|---|
| `boot()` | Once per process | Loads saved state; drops old patches if the store version changed; detects a crashed previous start and falls back; for code patches, reads what native code loaded. **Never throws** |
| `markBootSuccessful()` / `markBootSuccessfulAfterFirstFrame(stableFor:)` | Once the app is stable | Confirms the running patch, makes it "last good", reports `patch_boot_succeeded`. `markBootSuccessfulAfterFirstFrame` simply waits `stableFor` (default 10 s) from the moment you call it |
| `checkForUpdate({force})` | Whenever your app calls it (no automatic timer) | Registers if needed, checks, verifies, downloads and stages. Respects the server's check interval unless `force: true`. **Never throws**; returns an `UpdateResult` |
| `setChannel(name)` | Tester settings | Saves a channel for this device (`null` = back to the build's default) |
| `activePatch`, `activePatchNumber`, `installationId`, `channel` | Any time after `boot()` | Current state for your UI or logs |

### Registration and the release identity

On the first check the client creates a random installation id, stores it, and registers with the
server (slug, installation id, platform, CPU ABI, `releaseVersion`, channel). It keeps the device
token and registers again automatically when the server answers `401`.

`releaseVersion` must equal the version registered on the server **exactly** (`1.0.0+1`, not
`1.0.0`). If the server does not know the version, every check answers "no update" and the app
simply runs its store code.

### Download and verification

For an offered patch the client refuses, in this order: a patch that already failed on this
device, a replay (number not newer than the highest accepted, unless it is the server's rollback
target), a wrong arch, a wrong `runtime_abi`, an unsupported format, and an unknown `key_id`. It
then **verifies the ES256 signature before downloading**, downloads with a size limit, and checks
the SHA-256. Code patches also check that the store code matches the patch's base hash and that
the rebuilt code matches the signed result hash ([security.md](security.md#device-side-checks)).

### Activation

A staged patch runs on the **next app start**, never while the app is running. After a check
returns `stagedRestartRequired`, you can tell the user to restart, or just wait for the next
natural start.

The client checks **only when your app calls `checkForUpdate()`**; it has no timer of its own.
The helper above checks once per app start. Between checks the client respects the server's
`next_check_after_seconds` (30 minutes by default, ±20% jitter): an earlier call returns
`upToDate` with the message `checked recently`, unless you pass `force: true`. If you want
checks while the app stays open (for example when it returns to the foreground), call
`checkForUpdate()` from your own lifecycle code.

## 5. Handle results and errors

`checkForUpdate()` returns an `UpdateResult` with a `status`, an optional `patchNumber` and a
`message`:

| `UpdateStatus` | Meaning | Typical action |
|---|---|---|
| `upToDate` | Nothing new (or "checked recently") | None |
| `stagedRestartRequired` | A patch was downloaded, verified and staged | Runs on the next start |
| `rollbackRestartRequired` | The running patch was rolled back or revoked on the server | The fallback runs on the next start |
| `rejected` | The client refused what the server offered | Log `message` (e.g. `signature invalid`, `hash mismatch`, `unknown signing key prod-2`) and investigate ([troubleshooting.md](troubleshooting.md#the-app-refuses-a-patch)) |
| `failed` | Network or server problem | Nothing: the app keeps its current code and retries later |

The example app shows these on screen:

```dart
final result = await ota.checkForUpdate(force: true);
final text = switch (result.status) {
  UpdateStatus.upToDate => 'Up to date',
  UpdateStatus.stagedRestartRequired => 'Patch ${result.patchNumber} ready. Close and reopen the app.',
  UpdateStatus.rollbackRestartRequired => 'Current patch was rolled back. Close and reopen the app.',
  UpdateStatus.rejected => 'Refused: ${result.message}',
  UpdateStatus.failed => 'Failed: ${result.message}',
};
```

## 6. Rollback behaviour on the device

- **Crash protection.** If a new patch starts but `markBootSuccessful` is never reached, the next
  start runs the last good patch (or the store code) and reports `patch_boot_failed` and
  `patch_auto_rollback`. That patch is never tried again on this device, and the device tells the
  server to skip it. For code patches this happens in native code, so it works even if Dart never
  starts. A process started only for a push message or a background job never counts as a failed
  start.
- **Server rollback or revoke.** Every check response lists bad patch numbers. If the running
  patch is on that list, the client switches back to the last good code (or the server's
  `rollback_to_patch_number`) on the next start.
- **New store version.** When `releaseVersion` changes, all old patches are deleted locally.
- **Not covered:** a crash that happens *after* the patch was confirmed. Use server rollback.

Choose the confirmation delay with care: too short, and a patch that crashes a few seconds later
is confirmed as good; too long, and a user who closes the app quickly causes a false failure.

## 7. Build settings for every build

Every build you give to anyone must carry the OTA settings, plus your app's own:

```bash
--dart-define=OTA_SERVER_URL=https://ota.example.com \
--dart-define=OTA_PUBLIC_KEY=prod-1:BIi7De… \
--dart-define=OTA_CHANNEL=staging          # tester builds only; production builds leave it out
```

Then register and ship the build as described in
[releases-and-patches.md](releases-and-patches.md).

## Store policy

Google Play forbids apps from downloading executable code "such as dex, JAR, .so files", except
"code that runs in a virtual machine or an interpreter". A Punit code patch replaces Dart AOT
code that the Dart VM inside Flutter runs; no Java, Kotlin or native code is downloaded. Google
has not ruled on this publicly. **Whether this is allowed for your app is your decision and your
responsibility.**

To make that decision explicit, the server refuses to publish code patches for a `public_store`
app until someone records an approval:

```bash
ota app approve-policy shop-app --reason "Dart-only code patches; reviewed by <name>"
```

Apple forbids downloading new native code on iOS. Punit has no iOS code-patch support.

## Checklist

- [ ] `ota_client` dependency added; `flutter pub get` done
- [ ] App created on the server with the right `distribution`
- [ ] Production public key (not a dev key) passed as `OTA_PUBLIC_KEY`
- [ ] `releaseVersion` built from the full version (`version+buildNumber`)
- [ ] `markBootSuccessful` reached only once the app is really usable
- [ ] Production builds use `https://` and no `usesCleartextTraffic`
- [ ] Every shipped build registered with `ota release android` (code patches)
