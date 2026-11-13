# Compatibility and limitations

Flutter OTA System is an **experimental alpha**:
- It has been tested internally only: Linux for development, and Android phones.
- It is **not production-ready**.
- It has **not** been independently security-audited or load-tested.
- **No app store has reviewed or approved it.** Never assume store approval; see [Google Play](policy/google-play.md) and [Apple App Store](policy/apple-app-store.md).

## Compatibility

| Component | Status |
| --- | --- |
| Android | **Experimental**. The bytecode architecture was tested end to end on **one Android 13 arm64 phone** |
| ABI | **arm64-v8a** only |
| Developer machine (CLI, toolchain, builds) | **Linux x64** only. The toolchain's host binaries exist only for Linux |
| Flutter / Dart | **3.47.9 / 3.13.7**, with the Flutter OTA custom engine (engine `89c39edf`, Dart `416e33b`). No other version |
| Stock Flutter engine | Cannot load bytecode patches |
| iOS | Not implemented |
| macOS, Windows, Linux, web **apps** | Not implemented |
| Backend | Linux Docker stack tested. The single-server deploy (`deploy/`, Caddy) is a draft and not verified end to end |
| Packages on pub.dev | `flutter_ota_system` and `flutter_ota_cli` are **not published yet**. Use the Git and path installs from the [quick start](quick-start.md) |
| Toolchain distribution | **Not published yet**: no official download and no official signing key. Build it yourself ([toolchain management](toolchain-management.md#6-building-the-toolchain-yourself)) |

The original alpha (`v0.1.0-alpha.1`, server-signed `libapp.so` patches) runs on stock Flutter 3.44.9+. It has its own limits, listed [below](#original-alpha-limitations).

## Bytecode architecture limitations

**Adopting it**
- **Custom engine.** Your app must be built with the Flutter OTA toolchain. Adopting it, or moving to a new toolchain, needs a **new store release**.
- **One Flutter version.** Only Flutter 3.47.9 is supported today. Each new Flutter version needs an engine and toolchain build by the project owner.

**What can be patched**
- **Feature packages only.** Only code in local feature packages can be patched. Anything else needs a new store release:
  - the app package itself;
  - shared packages;
  - `pubspec.lock` changes;
  - native code and assets;
  - new local packages;
  - dependencies that are not in the store build.

  See [feature patching](feature-patching.md).
- **No whole-app patching.** Patching arbitrary code without feature packages is a research topic. It is not supported or promised.
- **Store-build libraries only.** A patch can only use Flutter, Dart and package libraries that the store build already contains.

**Performance and size**
- **Performance.** Patched code runs in the bytecode interpreter. UI and normal app logic worked well in testing (patch load 3.8 ms, start-up 200–260 ms with a patch, on one phone). **CPU-heavy code is much slower** than compiled code: up to 165× in earlier measurements.
- **Binary size.** The store build must include everything a patch might use, so `libapp.so` grows. It was about 22–26 MB for small test apps. The cost for large apps is **not measured**.

**Security**
- The verifier process is not a sandbox (same Linux user).
- Some malformed patches are contained rather than rejected cleanly.
- The verifier is not a type checker.

See [security](security.md#known-security-limitations).

**Tooling**
- Promotion from staging to production uses the Python `ota` CLI or the API; `flutter_ota` has no promote command.
- `flutter_ota rollback --reason` is not stored, because the API has no reason field.
- Every store release rebuilds the Android project from scratch, because it builds from a neutral copy.
- A partly failed release registration has no automatic resume.
- Approvals (extra approver signatures) are tested on Linux only.

## Not tested yet

These are planned for the final testing phase:
- more Android devices, versions and manufacturers;
- large real apps: binary size, start-up, memory, frame timing;
- crash-recovery paths with the production SDK on a device (they were tested on a device with the earlier prototype runtime);
- OS eviction and phone reboots during activation;
- AAB delivery through Google Play internal testing (to test compatibility, not to claim approval);
- toolchain upgrades to a second Flutter version;
- security fuzzing of uploads and of the device verifier;
- load and scale testing of the backend.

## Original alpha limitations

`v0.1.0-alpha.1`, with `mock-v1` and `aot-bidiff-android-v1` patches:
- **The server holds the patch-signing key.** One key covers all apps, with no rotation tooling. See [security](security.md#original-alpha-server-held-key).
- **The code patch replaces `libapp.so`.** It is experimental, tested manually on a few devices, and carries store-policy considerations.
- Flutter **3.44.9 or newer** on Android.
- The native start re-checks the patch hash, but not its signature, and `boot.json` is not signed.

## Server and operations

- **One shared admin API key.** No users, roles (RBAC), MFA or audit log.
- **No rate limiting.** Device registration is open, and device tokens cannot be revoked one by one.
- **No short-lived download URLs.** Patch URLs are public and permanent; integrity comes from signatures.
- **Restore is not tested.** Backups (`./flutter-ota-system.sh backup`, `deploy/backup.sh`) are not encrypted.
- **Channels can be created only through the API** (`POST /v1/admin/apps/{slug}/channels`). The CLI has no command for it.

## Known issues

| Issue | Effect | Workaround |
| --- | --- | --- |
| A failed `ota patch android` (original alpha) leaves an empty draft patch | The patch number is used up; publishing it fails with `422 Patch has no artifacts` | Delete it, or ignore it and run the command again |
| Stale patch display after a rollback | The admin page still shows the old rollout of a rolled-back patch; the demo app shows "none" before the restart | Cosmetic; restart the app |
| `/health/ready` returns 500 instead of 503 while the database restarts | Monitors see an error, not "not ready" | It recovers by itself when the database is back |
