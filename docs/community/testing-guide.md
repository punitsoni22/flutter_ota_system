# Testing guide: help test Flutter OTA System

Flutter OTA System has been tested internally on one Linux development environment and a small
number of Android devices (Android 13, `arm64-v8a`); the bytecode architecture on one phone. We need reports from
other machines, phones, Android versions and Flutter versions before anyone can call it reliable.

**A report that says "it worked on my setup" is just as useful as a bug report.** It tells us
which environments work.

- **Time:** about 30 minutes for the server and demo; about 1 hour with a phone.
- **You need:** Linux x64 with Docker Engine and Compose v2.20+, Git and curl. For the app part:
  the `flutter_ota` CLI and toolchain (see the [quick start](../quick-start.md)), Python 3.10+ for
  the `ota` admin CLI, and an **arm64** Android phone.
- **macOS or Windows:** the server stack is not tested there (reports welcome; say which Docker
  setup you used). The `flutter_ota` toolchain runs on Linux x64 only.

> [!CAUTION]
> Use the local test stack only. Never paste `.env` contents, admin API keys, signing keys
> (`*.pem`), tokens or personal data into an issue. Report security vulnerabilities privately
> ([SECURITY.md](../../SECURITY.md)), never in public issues.

## What to test

Run the areas you can, in order. Each row links to the exact commands.

| # | Area | How | What "works" looks like |
|---|---|---|---|
| 1 | Fresh server installation | `./flutter-ota-system.sh setup` ([self-hosting §2](../self-hosting.md#2-get-the-code-and-run-setup)) | Setup ends with the URLs; no errors |
| 2 | Server check | `./flutter-ota-system.sh demo` ([self-hosting §4](../self-hosting.md#4-verify-the-server-seed-publish-a-test-patch-check)) | Last line: `RESULT: all checks passed …` |
| 3 | Toolchain | `flutter_ota toolchain install` (downloads and verifies it), then `flutter_ota toolchain doctor` | Every doctor check `[ok]` |
| 4 | Project setup | `flutter_ota init`, `keys init`, `doctor` in your app or the [demo app](../../packages/ota_client/example/README.md) ([quick start](../quick-start.md)) | Every doctor check `[ok]` |
| 5 | Store release | `flutter_ota release android --kind apk`, install the APK on an arm64 phone | The app starts; the log shows `NO_PATCH the store code runs` |
| 6 | Feature patch | Change a feature package (try a freezed model), `flutter_ota patch android --channel staging`, promote | The command ends with "uploaded"; the patch shows in `flutter_ota status` |
| 7 | Delivery | Open the app, then restart it | Log: `VERIFY_PROCESS status=OK`, then `LOADED patch #N`; the new feature shows; no reinstall |
| 8 | Refusals | Change a shared package, or add a dynamic call | `patch android` refuses with a clear reason |
| 9 | Rollback | `flutter_ota rollback`, then restart the app twice | Back on the store code (or the previous patch) |
| 10 | Your phone and app | Repeat 5–9 on your device and with your own feature code | Report what worked and what did not |

**Original alpha** (`ota`, `mock-v1` / `aot-bidiff-android-v1`): the server check in row 2 covers
the `mock-v1` pipeline. See [releases and patches](../releases-and-patches.md#original-alpha-patch-formats).

## What to report

Open a **[Test report](https://github.com/punitsoni22/flutter_ota_system/issues/new?template=test_report.yml)**
issue (for things that worked or failed), or a **[Bug report](https://github.com/punitsoni22/flutter_ota_system/issues/new?template=bug_report.yml)**
for one specific problem. Please include:

- **Environment:** host OS and version, `docker version`, `docker compose version`;
- **Flutter:** `flutter --version`;
- **Device:** phone model or emulator, Android version, ABI (`adb shell getprop ro.product.cpu.abi`);
- **Flutter OTA System version:** `flutter_ota --version` (CLI), the `flutter_ota_system` version from
  `pubspec.lock`, or the commit (`git rev-parse --short HEAD`);
- **Which rows you tested** and the result of each;
- **Installation problems:** the command and its full output;
- **Patch failures:** the result message from the app and the CLI output;
- **Logs, with secrets removed:** `./flutter-ota-system.sh logs api`, `adb logcat`;
- **Suggestions:** anything that was confusing, missing or slow.

Questions and ideas that are not bugs: use
[GitHub Discussions](https://github.com/punitsoni22/flutter_ota_system/discussions) if it is
enabled, or a [feature request](https://github.com/punitsoni22/flutter_ota_system/issues/new?template=feature_request.yml).

## Clean up

`./flutter-ota-system.sh stop` stops the stack and keeps everything. `./flutter-ota-system.sh reset`
deletes the local database, patch files and dev signing key after you confirm. Run
`adb reverse --remove-all` if you used `adb reverse`.
