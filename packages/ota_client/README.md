# flutter_ota_system

The Flutter client SDK of **[Flutter OTA System](https://github.com/punitsoni22/flutter_ota_system)**:
an experimental, open-source, **self-hosted** over-the-air (OTA) patch system for Flutter apps.

> [!WARNING]
> **Experimental alpha (0.1.0-alpha.1). Not production-ready.** Tested internally only, with
> Android apps on a small number of devices. **Android is the only supported platform.** iOS,
> macOS, Windows, Linux and web are not supported or tested. Testing on some Android devices
> does not establish compatibility with every device, OS version, ABI or Flutter version.

## What it is and why it exists

Flutter OTA System lets you ship fixes to an installed Flutter app without a new store release,
using **your own server**: you run the backend (FastAPI + PostgreSQL + file storage), keep the
signing key, and decide who gets which patch. There is no hosted service.

This package is the part that runs inside your app. It:

- registers the installation with your server and asks it for patches (per channel and
  percentage rollout);
- downloads a patch and verifies its **size**, **SHA-256** and **ES256 signature** against
  public keys compiled into your app, before it is ever used;
- **stages** it and activates it on the **next app start** (running code is never swapped
  live);
- protects the start: a new patch that never confirms a successful start is skipped next time,
  and the last good patch or the store build runs (**automatic fallback**);
- applies server-side **rollbacks and revocations**, and reports boot success/failure counters.

Two runtimes decide what a patch is:

| Runtime | Format | What a patch changes | Status |
|---|---|---|---|
| `MockPatchRuntime` | `mock-v1` | An inert data file (e.g. JSON config) that your app reads at start. No code runs | Tested on Android |
| `AotPatchRuntime` | `aot-bidiff-android-v1` | The app's compiled Dart code (`libapp.so`), Android release builds only | **Experimental** |

## How it connects to your server

```
your app ── flutter_ota_system ──HTTPS──▶ Flutter OTA System server (/v1/devices/register,
                                          /v1/updates/check, /v1/events/batch)
                         ◀── signed patch files from your file server / CDN / bucket
```

You publish patches with the project's `ota` CLI; the server signs them with your key. See the
[installation guide](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/installation.md)
and the [Flutter integration guide](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/flutter-integration.md).

## Prerequisites

- A running Flutter OTA System server you control, reachable over **HTTPS** from release builds.
- From the server, for your app: the **app slug**, the **application id** (`ota app list`,
  field `"id"`), and the **public signing key** (`ota key show --dart`).
- Flutter **3.44.9** or newer (Dart 3.12.2+). Only Flutter 3.44.9 has been tested.
- Android: `minSdk` 21 or higher, Java 17. The app needs the `INTERNET` permission.

## Installation

After the first pub.dev publication (not published yet):

```bash
flutter pub add flutter_ota_system
```

Until then, use the Git repository:

```yaml
dependencies:
  flutter_ota_system:
    git:
      url: https://github.com/punitsoni22/flutter_ota_system.git
      path: packages/ota_client
```

The Android part registers itself (a content provider in the plugin's manifest); no
`MainActivity` changes are needed.

## Configuration

```dart
import 'package:flutter_ota_system/flutter_ota_system.dart';

final config = OtaConfig(
  serverUrl: 'https://ota.example.com',
  appSlug: 'shop-app',
  applicationId: '12ebc1fd-abb9-4ee3-83c3-78deb9fadaa8',
  releaseVersion: '1.0.0+1',
  publicKeys: const {'prod-1': 'BIi7De…'},
  runtime: MockPatchRuntime(),
);
```

| Field | Required | Meaning |
|---|---|---|
| `serverUrl` | yes | Your server. Release builds: `https://` only. Debug builds may also use `http://localhost` (e.g. `adb reverse`) and `http://10.0.2.2` (emulator) |
| `appSlug` | yes | The app's slug on the server (`ota app create <slug> …`) |
| `applicationId` | yes | The app's **server id** (UUID, `"id"` in `ota app list`). **Not** the Android package name. Responses and patches of any other application are refused |
| `releaseVersion` | yes | This store build's version **with build number**, exactly as registered, e.g. `'${info.version}+${info.buildNumber}'` from `package_info_plus` |
| `publicKeys` | yes | Trusted keys, `{key id: base64 P-256 point}` from `ota key show --dart`. Several keys allow rotation |
| `runtime` | yes | `MockPatchRuntime()` or `AotPatchRuntime()` |
| `channel` | no | Default channel of this build (default `production`) |
| `httpClient` | no | Custom `package:http` client (proxy, certificate pinning). URL rules still apply |

## Basic initialization

With `MockPatchRuntime`, boot **before** `runApp` so the active payload is ready for the first
screen:

```dart
final runtime = MockPatchRuntime();
late final OtaClient ota;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ota = OtaClient(OtaConfig(/* … */ runtime: runtime));
  await ota.boot();                              // picks store build / last good / new patch
  final payload = runtime.activePayload;         // null = store build
  runApp(MyApp(configBytes: payload));
  ota.markBootSuccessfulAfterFirstFrame();       // confirms the start after 10 s
  unawaited(ota.checkForUpdate());               // never block startup on the network
}
```

With `AotPatchRuntime`, the code to run is chosen natively before Dart starts, so you can also
create the client and call `boot()` after the first frame.

## Update-check flow

```dart
final result = await ota.checkForUpdate();   // never throws
switch (result.status) {
  case UpdateStatus.stagedRestartRequired:   // downloaded + verified; runs after a restart
  case UpdateStatus.rollbackRestartRequired: // current patch rolled back/revoked; fallback after a restart
  case UpdateStatus.upToDate:
  case UpdateStatus.rejected:                // refused: see result.message (signature, hash, URL, …)
  case UpdateStatus.failed:                  // network/server problem or timeout
}
```

`checkForUpdate` respects the server's check interval unless you pass `force: true`, and
concurrent calls share one check. The client has no timer: call it when it suits your app (for
example at start and when the app resumes). Testers can switch channels with
`ota.setChannel('staging')`.

## Patch activation

A staged patch becomes active on the **next cold start**. The new patch must then be
confirmed with `markBootSuccessful()` (or `markBootSuccessfulAfterFirstFrame()`, which calls it
after a delay that starts when you call it). If the app dies before that, the next start skips
the patch and runs the last good patch or the store build, and the server is told
(`patch_boot_failed`). `ota.activePatch` / `ota.activePatchNumber` tell you what runs now.

## Android requirements

- `minSdk` 21+, Java 17, `INTERNET` permission.
- Code patches (`AotPatchRuntime`) work only in **release** builds, only for the exact store
  build registered with `ota release android`, built with the same Flutter version, and only
  for changes in Dart code. Debug builds run Dart in JIT mode and accept no code patches.
- Android 9+ blocks plain HTTP by default; release builds of this SDK refuse it anyway.
- **Not compatible** with apps or plugins that call `FlutterInjector.setInstance(...)`: once a
  code patch is active, the plugin reads the Flutter injector at process start.

## Troubleshooting

| Result | Likely cause |
|---|---|
| `failed`, `insecure URL … release builds require https://` | Release builds need an `https://` server URL |
| `rejected`, `application id mismatch` | `applicationId` is not this app's server id (check `ota app list`) |
| `rejected`, `unknown signing key …` / `signature invalid` | The app trusts a different key than the server signs with |
| `rejected`, `invalid patch id` / `insecure redirect …` | The response or a redirect is not from an unmodified, HTTPS-served server |
| `failed`, `TimeoutException …` | Server or file server not answering; the next check retries |
| Patch staged but never active | The app was not fully restarted, or the new patch was never confirmed and was skipped |

More: [troubleshooting guide](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/troubleshooting.md).

## Security considerations

- Patches are accepted only with a valid **ES256 signature** from a key compiled into the app,
  the exact **SHA-256** and size, for this application, release, CPU ABI and runtime, and with a
  patch number higher than any accepted before (anti-replay; server rollbacks excepted).
- Release builds use **HTTPS only**; redirects are checked hop by hop, never downgraded to HTTP,
  and the device token is not forwarded to another host. Downloads time out.
- The server holds the private signing key and signs what an admin uploads: protect the server
  and its admin key like the key itself. See the
  [security documentation](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/security.md).
- **Store policies:** the experimental `AotPatchRuntime` downloads and loads native executable
  code. Do not use it in Google Play-distributed applications unless you have independently
  reviewed and confirmed compliance with applicable Google Play policies. No store has reviewed
  or approved this project.
- The SDK sends a random installation id, the app version, platform, CPU ABI, channel and
  boot-success/failure events to **your** server; declare this in your app's privacy
  disclosures (e.g. Google Play Data safety) as applicable.

## Current limitations

- Android only; no iOS code patches; experimental code patches.
- No background timer, no live code swap, no restart API: patches apply on the next cold start.
- A patch that crashes **after** being confirmed is not rolled back automatically; use a
  server-side rollback. Rollback and revocation reach a device only when the running code calls
  `checkForUpdate()`, so never ship a patch that removes the OTA calls.
- Patch ids and download URLs are not covered by the signature (protocol v1); the client
  validates them strictly instead. Signing them is planned for protocol v2.
- See [limitations](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/limitations.md)
  and [known issues](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/known-issues.md).

## Development

From `packages/ota_client` in the repository:

```bash
flutter pub get && flutter analyze && flutter test
```

The Android code has JVM unit tests (`android/src/test`). They are not run in CI; run them
locally through the repository's example app, which hosts the plugin (needs JDK 17 or newer):

```bash
cd ../../example_app
flutter build apk --config-only          # creates android/gradlew and local.properties
cd android && ./gradlew :flutter_ota_system:testDebugUnitTest
```

## Links and licence

- Repository: <https://github.com/punitsoni22/flutter_ota_system>
- Issues: <https://github.com/punitsoni22/flutter_ota_system/issues>
- Security reports: see [SECURITY.md](https://github.com/punitsoni22/flutter_ota_system/blob/main/SECURITY.md)

Apache License 2.0, Copyright The Punit Authors. Contains an implementation of the bspatch
algorithm by Colin Percival (BSD-2-Clause); see `lib/src/bsdiff.dart` and
[THIRD_PARTY_NOTICES.md](https://github.com/punitsoni22/flutter_ota_system/blob/main/THIRD_PARTY_NOTICES.md).
