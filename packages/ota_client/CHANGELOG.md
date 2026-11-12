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
