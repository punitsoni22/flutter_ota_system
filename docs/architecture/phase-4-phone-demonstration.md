# Phase 4 phone demonstration (milestone 4I)

Date: 2026-11-13. Device: one Android 13 arm64 phone, USB. Experimental alpha.

**This proves the integration works end to end. It does not mean production readiness, and it says nothing about Google Play approval.** Comprehensive testing is a separate final phase.

## Acceptance criterion (owner)

> A developer changes normal Flutter feature code, runs one command (`flutter_ota patch android`), and the installed app receives the updated feature without reinstalling the APK.

**Result: met.**

## Setup

- **App:** the canonical demo, `packages/ota_client/example`. It has a `products` feature package (freezed + json_serializable model, API, entity, repository, controller, screen) and a shared `core` package.
- **Backend:** run locally on the development machine (SQLite, local storage). The phone reaches it through `adb reverse`, and so does the demo product API.
- **Toolchain:** `flutter-3.47.9-ota.1`, installed by `flutter_ota toolchain install` from a locally built, signed index. Nothing was published.

## Steps and results

| Step | Command / action | Result |
| --- | --- | --- |
| 1 | `flutter_ota init --app-id <uuid>` | `flutter_ota.yaml` contains only `app_id` |
| 2 | `flutter_ota keys init` | offline root key and signer key created locally; only the public key and certificate were registered |
| 3 | `flutter_ota toolchain install`, `flutter_ota doctor` | toolchain verified and pinned in `flutter_ota.lock`; all doctor checks `[ok]` |
| 4 | `flutter_ota release android --kind apk` | built with the custom engine in 5 min 33 s; release registered (`libapp.so` `d570a786…`); APK `d0fd943a…` installed on the phone |
| 5 | store app on the phone | "Products (v1)"; footer "active patch: none (store code)"; no update |
| 6 | developer edits the products feature | endpoint `/v1` → `/v2`; `rating` field added to the freezed model; `build_runner` regenerated `.freezed.dart` / `.g.dart`; entity, repository and UI changed (7 files) |
| 7 | `flutter_ota patch android --channel staging` | 8.9 s, in order: change detection (7 files), generated code up to date, rename, guard, `dart2bytecode`, reference verifier OK (20,877 B, 69 functions), local signature, upload (the server verified it), published to staging |
| 8 | promote to production (existing rollout endpoint) | published |
| 9 | start the app on the phone | patch downloaded and verified (signature, hashes, compatibility); separate verifier process OK in 295 ms; staged for the next start |
| 10 | restart the app | patch activated and loaded in 3.8 ms; start confirmed (PROBATIONARY → ACTIVE). Screen: **"Products (v2, with rating)"**, star ratings from the v2 API |
| 11 | no reinstall | installed APK SHA-256 identical before and after (`d0fd943a…`); `lastUpdateTime` unchanged; `libapp.so` in the installed APK identical to the store build (`d570a786…`) |
| 12 | server rollback of the patch | next start: ROLLED_BACK → BLACKLISTED. The start after that runs the store code ("Products (v1)"). The older patch #1 offered again was refused as a replay |

**Start-up timings** (from the `STARTUP` log line):

| Situation | Total | Native | `libapp.so` hash | Verification | Module load |
| --- | --- | --- | --- | --- | --- |
| No patch, first start after install | 1,447 ms | — | — | — | — |
| No patch, later starts | 108–125 ms | — | — | — | — |
| With the patch | 262 ms | 121 ms | 11 ms | 125 ms | 3.8 ms |
| With the patch, cached | 198 ms | — | — | 59 ms | — |

## Bugs found by the demonstration (fixed, commit `5f4afff`)

1. **Stale-codegen check.** A path dependency outside the project (the SDK) broke in the clean copy.
2. **`patch_guard`.** It treated `package:web`, reached only through `package:http`'s browser-only import, as patch code. That was a false rejection, and it would hit most real apps.
3. **Patch manifest.** It claimed dev-only and other-platform packages, so the phone correctly refused patch #1 with `missing_host_package`.

The server's existing promotion rule correctly refused publishing straight to `production` without staging first.

## Notes and limits

- **Store build path.** The demo's store build was made with commit `ad60154`, before the neutral-copy fix (`716c86f`). The path fix was verified separately with a real build: 0 home-path hits.
- **One device only.** Not tested here: other devices, other Android versions, OS eviction, and large apps (store binary size and start-up cost of the full dynamic interface).
- **CLI gap.** There is no `flutter_ota` command yet for promotion or rollback. The demo used the existing backend endpoints; this is planned for milestone 4H (`status`, `rollback`).
