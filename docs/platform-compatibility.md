# Platform and Flutter compatibility

What has actually been tested, what the SDK supports, and which Flutter internals the Android
code-patch runtime depends on. State as of **2026-11-12** (`flutter_ota_system` 0.1.0-alpha.1).
Code that might run on a platform is not the same as a supported or tested platform.

## Platforms

| Platform | Status |
|---|---|
| Android | Implemented; internally tested on a small number of devices |
| iOS | Not implemented |
| Linux | Not supported as a client (used only as the development machine) |
| Windows | Not implemented |
| macOS | Not implemented |
| Web | Not implemented |

The package's `pubspec.yaml` declares **only** `android` under `flutter.plugin.platforms`
(Flutter's mechanism for declaring a plugin's platforms, see
[Developing packages & plugins](https://docs.flutter.dev/packages-and-plugins/developing-packages)),
so pub.dev lists Android only. The server and CLI run on Linux (tested) with Docker.

## What has been tested

| Item | Tested |
|---|---|
| Flutter / Dart used by the maintainers | **Flutter 3.44.9, Dart 3.12.2** |
| CI (analysis and unit tests only) | The current Flutter stable on GitHub Actions (3.50.0 at the time of writing). CI does not build Android apps or run device tests |
| Android device | One **Android 13** phone (arm64-v8a), over USB with `adb reverse`, against the local Docker stack |
| Development machine | Linux |
| `mock-v1` (data) patches on the phone | Download, verification, staging, activation after restart; wrong application id and HTTPS rules (2026-11-12, current code) |
| Android **code patches** on the phone | Activation, crash fallback, rollback and policy gate were tested on **2026-11-11**, before the SDK changes of PR #17 and PR #18 (patch-id validation, HTTPS rules, package rename and Android namespace). **Not re-run on the current code.** After those changes, a release build of an external test app that uses `AotPatchRuntime` was checked to start and to reach the native plugin, without a code patch |
| Independent validation | **None.** No independent test, audit or production deployment |

Android testing on one phone does not establish compatibility with other devices, Android
versions, CPU ABIs (`armeabi-v7a`, `x86_64` were not tested on devices) or Flutter versions.

## Package requirements

- Dart `^3.12.2`, Flutter `>=3.44.9` (only 3.44.9 tested on devices).
- Android `minSdk` 21, Java 17, `INTERNET` permission. Release builds need an `https://` server.

## Flutter internals the code-patch runtime relies on

The Android code-patch runtime uses **stock Flutter** (no engine fork), but depends on details
that Flutter does not promise to keep stable:

| Mechanism | Where | Risk |
|---|---|---|
| `FlutterInjector.instance().flutterLoader()` with `startInitialization` and `ensureInitializationComplete(context, args)`, called from a content provider before `Application.onCreate` | [`OtaBoot.java`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/android/src/main/java/io/github/punitsoni22/flutter_ota_system/OtaBoot.java) | Initialization order and APIs of the embedding can change. Reading the injector early means apps or plugins that later call `FlutterInjector.setInstance(...)` fail once a code patch is active |
| The engine flag `--aot-shared-library-name=<path>` | `OtaBoot.java` | In Flutter 3.44.9 the embedding handles it in a flag system with a release-build allow-list and deprecated aliases, and silently ignores paths outside the app's internal storage. A future version could refuse or rename it, and patches would then **silently stop applying** (the store code runs) |
| `libapp.so` layout in the APK (`lib/<abi>/libapp.so`, also inside split APKs) | `OtaClientPlugin.java`, `cli/android.py` | Packaging changes would break base extraction and diffing |
| A patch is a diff of one exact `libapp.so` | `aot_runtime.dart` | Every Flutter upgrade changes `libapp.so`: a patch must be built with exactly the release's Flutter version |
| Debug builds run Dart in JIT mode | `OtaBoot.java` | Code patches work only in release (and profile) builds |

## Before upgrading Flutter

1. Read the release notes of the Flutter embedding / engine for changes to `FlutterLoader`, engine
   flags and AOT library loading.
2. Rebuild your app and register a **new store release** (`ota release android`); old patches do
   not apply to it.
3. On real devices, test the whole flow with that Flutter version: publish a code patch, restart,
   confirm the new code runs (not just the reported patch number), force a crash to test
   fallback, and test server rollback.
4. Run the package's tests (`flutter test`) and analysis with the new version.

Known gaps are listed in [limitations.md](limitations.md); security limitations in
[security.md](security.md).
