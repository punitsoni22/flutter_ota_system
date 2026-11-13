## Unreleased

Additive; the `0.1.0-alpha.1` API, wire formats, method channels and storage are unchanged.
**Experimental alpha, Android arm64 only, needs the Flutter OTA System toolchain (Flutter 3.47.9).**

* New bytecode runtime: `FlutterOta.initialize()`, `FlutterOta.feature<T>()`, `OtaFeature`,
  status getters, `FlutterOta.lastStartupTimings`, `FlutterOta.checkForUpdate()`. Configuration
  comes from the `FLUTTER_OTA_CONFIG` dart-define; without it OTA is disabled (no crash).
* Developer-signed `dbc-v1` patches (`OTAPRT02` container): the Phase 3C verification pipeline
  (canonical manifest, root-certified ES256 keys, approvals, toolchain id, revocation lists) moved
  into the package, with its 69 tests.
* New patches are loaded once in a separate `:flutter_ota_verify` process before activation, and
  activated at the next start. Crash state machine with `ApplicationExitInfo` attribution,
  previous-patch restore and re-verification of the stored patch at every start.
* Android: channel `flutter_ota/runtime` and the service `FlutterOtaVerifierService`.
* The bytecode runtime also accepts plain `http://` to loopback hosts (`127.0.0.1`, `localhost`,
  `[::1]`) in release builds, for local tests through `adb reverse`. `OtaClient` is unchanged.
* Tested end to end on one Android 13 arm64 phone (a feature patch with a freezed model change,
  delivered without reinstalling the APK; rollback to the store code).

## 0.1.0-alpha.1

First pub.dev release of the Flutter OTA System client SDK (package `flutter_ota_system`;
earlier versions of this code were used from the Git repository as `ota_client`).
**Experimental, not production-ready. Android only.** Versioned independently of the Flutter OTA
System server and platform.

* `OtaClient` and `OtaConfig`: device registration, update checks per channel, staged patches
  that activate on the next app start, boot protection with automatic fallback to the last good
  patch or the store build, server-side rollback and revocation, boot telemetry.
* Patch verification before use: ES256 signature against compiled-in keys (several keys for
  rotation), SHA-256, exact size, application, release, CPU ABI, runtime and format, and
  anti-replay.
* Runtimes: `MockPatchRuntime` (`mock-v1`, inert data such as JSON config) and the experimental
  `AotPatchRuntime` (`aot-bidiff-android-v1`, Android code patches, release builds only).
* `OtaConfig.applicationId` (the server application id) is **required**; responses for another
  application are refused.
* Security: patch ids must be lowercase UUIDs (checked in Dart and Android before any file
  operation); release and profile builds use `https://` only, debug builds may also use
  `http://localhost` and `http://10.0.2.2`; redirects are checked hop by hop, never downgraded to
  HTTP, and do not forward the device token to another host; connect, request and download
  timeouts.
* Android: Java package and namespace `io.github.punitsoni22.flutter_ota_system`
  (previously `dev.flutterota.ota_client`); the plugin registers itself, no app changes needed.
* Public API: `OtaClient`, `OtaConfig`, `PatchRuntime`, `MockPatchRuntime`, `AotPatchRuntime`,
  `PatchRecord`, `UpdateResult`, `UpdateStatus`. Protocol and native-boot details are internal.
