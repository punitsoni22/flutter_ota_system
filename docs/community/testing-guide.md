# Testing guide: help test Flutter OTA System

Flutter OTA System v0.1.0-alpha.1 has been tested internally on one Linux development
environment and a small number of Android devices (Android 13, `arm64-v8a`). We need reports from
other machines, phones, Android versions and Flutter versions before anyone can call it reliable.

**A report that says "it worked on my setup" is just as useful as a bug report.** It tells us
which environments work.

- **Time:** about 30 minutes for the server and demo; about 1 hour with a phone.
- **You need:** Linux with Docker Engine and Compose v2.20+, Git and curl. For the app part:
  Flutter, Python 3.10+ (for the `ota` CLI) and an Android phone or emulator.
- **macOS or Windows:** not tested by the maintainers. A report from either is very welcome. Say
  which Docker setup you used (Docker Desktop, WSL 2, Colima, …).

> [!CAUTION]
> Use the local test stack only. Never paste `.env` contents, admin API keys, signing keys
> (`*.pem`), tokens or personal data into an issue. Report security vulnerabilities privately
> ([SECURITY.md](../../SECURITY.md)), never in public issues.

## What to test

Run the areas you can, in order. Each row links to the exact commands.

| # | Area | How | What "works" looks like |
|---|---|---|---|
| 1 | Fresh Docker installation | `./flutter-ota-system.sh setup` ([installation §2](../installation.md#2-get-the-code-and-run-setup)) | Setup ends with the URLs; no errors |
| 2 | Backend configuration | `./flutter-ota-system.sh status`; change a port or `OTA_CDN_BASE_URL` in `.env`, then `./flutter-ota-system.sh up` ([installation §3](../installation.md#3-check-the-stack), [configuration.md](../configuration.md)) | Health checks pass after the change |
| 3 | End-to-end demo | `./flutter-ota-system.sh demo` ([installation §4](../installation.md#4-run-the-demo-seed-publish-a-test-patch-verify)) | Last line: `RESULT: all checks passed …` |
| 4 | Flutter Android integration | Run the example app on a phone or emulator ([installation §8](../installation.md#8-run-the-example-app)), or add `ota_client` to your own app ([flutter-integration.md](../flutter-integration.md)) | The app starts on "Store build (no patch)" |
| 5 | Device registration | Start the app once, then open the admin page (`/admin`) and the app's release | The release shows `1 device` (or one more than before) |
| 6 | Full release creation | `ota release android my-app -- …` ([releases-and-patches.md](../releases-and-patches.md#android-code-patches)) | "Release … registered" for your ABIs |
| 7 | Patch generation | Change Dart code, then `ota patch android my-app --channel staging` | A patch per ABI, with its size |
| 8 | Patch publishing | Publish to `dev`/`staging`, then `ota patch promote <id> --percent 10` ([rollouts.md](../rollouts.md)) | The rollout shows on the admin page |
| 9 | Artifact downloading | Tap **Check for update now** in the app | "Patch N ready. Close and reopen the app." |
| 10 | Signature verification | Build the app once with a wrong `OTA_PUBLIC_KEY`, then check for an update | The patch is refused: `unknown signing key` or `signature invalid` ([troubleshooting](../troubleshooting.md#the-app-refuses-a-patch)) |
| 11 | Patch activation | Close the app fully and open it again | The patched banner or code; Active patch `#N` |
| 12 | Restart and recovery | The "Crash protection" case in [installation §9](../installation.md#9-try-more-cases-optional) | After the crash, the app is back on the previous patch, and the crashed patch is not offered again |
| 13 | Rollback | `ota patch rollback <id>`, check, restart ([installation §9](../installation.md#9-try-more-cases-optional)) | Back on the previous patch |

Rows 6 and 7 are **Android code patches**, which are experimental. They need a release build of
an app that uses `AotPatchRuntime` ([flutter-integration.md](../flutter-integration.md#code-patches-android-a-ready-made-helper)).
The example app uses `mock-v1` config patches, so rows 4, 5 and 9–13 work with it directly.

## What to report

Open a **[Test report](https://github.com/punitsoni22/flutter_ota_system/issues/new?template=test_report.yml)**
issue (for things that worked or failed), or a **[Bug report](https://github.com/punitsoni22/flutter_ota_system/issues/new?template=bug_report.yml)**
for one specific problem. Please include:

- **Environment:** host OS and version, `docker version`, `docker compose version`;
- **Flutter:** `flutter --version`;
- **Device:** phone model or emulator, Android version, ABI (`adb shell getprop ro.product.cpu.abi`);
- **Flutter OTA System version:** `v0.1.0-alpha.1` or the commit (`git rev-parse --short HEAD`);
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
