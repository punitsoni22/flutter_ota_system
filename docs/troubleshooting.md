# Troubleshooting

Each entry gives the **cause**, how to **diagnose** it and how to **fix** it. The messages are the
exact texts printed by the server, the CLI, the client or the scripts.

**First steps for any problem**

```bash
./flutter-ota-system.sh status                              # local stack: containers, health, URLs, key
curl http://localhost:8000/health/ready        # {"status":"ok"}? (use your server URL)
docker compose ps                              # all services "(healthy)"?
docker compose logs --tail=100 api             # server errors (local: ./flutter-ota-system.sh logs api)
adb logcat | grep -E "flutter_ota|OtaBoot|OTA:"  # Android device side
```

Bytecode architecture (`flutter_ota`): run `flutter_ota doctor` and `flutter_ota status`, and read
the device log with `adb logcat | grep flutter_ota`.

## `flutter_ota` and the bytecode runtime

| Message | Cause | Fix |
|---|---|---|
| `Because <app> depends on dynamic_modules from path which requires SDK version ^3.13.0, version solving failed.` (`flutter pub get`) | Your Flutter is older than the toolchain in `flutter_ota.lock`. After the first release the project depends on the toolchain's `dynamic_modules` loader, which needs that Dart version (3.13 or 3.14) | Use the Flutter version in `flutter_ota.lock` (3.47.9 or 3.50.0) for `flutter pub` and your IDE. `flutter_ota release`/`patch` always use the toolchain's own Flutter |
| `Flutter assets will be downloaded from file://…/toolchains/<id>/mirror. Make sure you trust this source!` (during `release android`) | Normal. Flutter prints this because the toolchain points it at the verified engine files inside its own cache (the overlay's local mirror) | Nothing to fix: those files were checked against the signed index when the toolchain was installed (`flutter_ota toolchain doctor` re-checks them) |
| `[x] android build tools: Gradle … < 9.3.1, …` (doctor) or `Skipping flutter-3.50.0-ota.1: needs newer Android build tools` | Flutter 3.50 refuses to build with older Gradle / Android Gradle plugin / Kotlin Gradle plugin versions | Raise them in `android/gradle/wrapper/gradle-wrapper.properties` and `android/settings.gradle(.kts)` (3.50: 9.3.1 / 9.1.1 / 2.4.10), then `flutter_ota upgrade` |
| `pubspec.lock changed since the release` when patching an older release after `flutter_ota upgrade` | The project's dependencies were re-resolved with the newer Flutter; the installed app was built with the release's versions | Patch the older release from its own code (release branch or tag), where `pubspec.lock` is the release's (a copy is in `.flutter_ota/releases/<id>/pubspec.lock`) |
| `[x] flutter_ota.lock: missing` (doctor) | No toolchain pinned yet | `flutter_ota toolchain install` in the app folder, then commit `flutter_ota.lock` |
| `Download of ... stopped at ...` / `Run the same command again to resume.` | The toolchain download was interrupted (network, Ctrl+C) | Run `flutter_ota toolchain install` again: it resumes where it stopped |
| `No trusted toolchain-signing keys are configured` or `... signed only by unknown key(s) ...` | The index you use is not signed by the key built into the CLI (for example a private mirror) | For a private mirror, trust its public key: `flutter_ota config add-toolchain-key <key_id> <public_key_base64>`. To use the official index again: `flutter_ota config unset toolchain-index-url` (and check `FLUTTER_OTA_TOOLCHAIN_INDEX` is not set). See [private mirrors](toolchain-management.md#25-private-mirrors) |
| `The toolchain index (serial N) is older than one already seen` | The index is older than one this machine already used | Use the current index of the mirror; an old index is never accepted |
| `flutter_ota --version` prints nothing (Ubuntu) | The snap-packaged `dart` can print nothing for very short programs. Real commands work | Run `flutter_ota --help` to check, or use an official Flutter install from flutter.dev instead of the snap |
| A toolchain error saying the toolchain is missing or changed | The pinned toolchain is not installed, or a file in it changed | `flutter_ota toolchain install --force`. The CLI never falls back to stock Flutter |
| `No certified patch-signing key for app ...` | No signer key and certificate on this machine | `flutter_ota keys init`, or get a certificate from whoever holds the root key |
| `... can be read by other users` | A private key file has loose permissions | `chmod 600 <the key file>` |
| `the certificate is for the development environment, but the release is production` | Signer certificate for another environment | Create a signer certificate for the release's environment |
| A patch is refused with "needs a new store release" (exit 3) | The change is outside feature packages, or changes dependencies, native code or assets | See [what needs a new store release](feature-patching.md#6-what-needs-a-new-store-release) |
| `The generated code of <package> is out of date (...)` | `build_runner` was not run after a model change | `dart run build_runner build --delete-conflicting-outputs` in that package |
| `patch_guard: ... dynamic function invocation` (exit 4) | Code calls a method on a `dynamic` value | Rewrite it with static types (casts, typed callbacks) |
| `The build also contains native libraries for x86_64, ...` (`release android`) | A plugin ships native libraries for other ABIs; the OTA engine exists for arm64-v8a only | Add the `abiFilters` block from the message to `android/app/build.gradle.kts` ([quick start, step 6](quick-start.md#6-prepare-the-app)), then run `release android` again. Nothing was registered |
| `The build does NOT contain the OTA engine` (`release android`) | A stock Flutter engine was picked up | `flutter_ota toolchain doctor`, delete `android/.gradle` and `build/`, then try again |
| `409 promotion_checks_failed ... has not been on a test channel` | Publishing straight to `production` | Publish to `staging` first (`patch android --channel staging`), test, then `ota patch promote <patch_id>`. To override on purpose: `--force --reason "…"` (logged) |
| Device log `DISABLED FLUTTER_OTA_CONFIG is not set` | The app was built with plain `flutter run` / `flutter build` | Build it with `flutter_ota release android` |
| Device log `REJECTED offered patch N: replay: sequence ...` | The server offers an older patch than the one the device already accepted | Normal after a rollback of a newer patch; publish a new patch |
| Device log `VERIFY_PROCESS status=REJECTED` / `CRASHED` | The verifier process refused or could not load the patch | The patch is never used. Check the patch with `flutter_ota patch android --dry-run` and report a bug |
| Device log `VERIFY_PROCESS status=EVICTED` | Android killed the verifier process for low memory | Nothing to do: the check is retried at a later update check (at most 3 times per patch) |
| A new patch ran, then the store code (or the previous patch) came back | The patch crashed the app twice before its start was confirmed, so the device rolled it back and blocklisted it | Roll it back on the server too (`flutter_ota rollback`), so other devices stop getting it. Fix the crash and ship a new patch |
| The phone cannot reach a local server | Release builds accept `http://` only to loopback | `adb reverse tcp:8000 tcp:8000` and use `http://127.0.0.1:8000` |

The sections below cover the server, the local stack and the **original alpha** `OtaClient` path.
For that path, log the `UpdateResult` returned by `checkForUpdate()`: its `status` and `message`
tell you which step failed.

## Docker and the local stack

| Message / symptom | Cause | Fix |
|---|---|---|
| `ERROR docker not found. Install Docker Engine (Linux) or Docker Desktop…` | Docker is not installed | Install it ([self-hosting](self-hosting.md#1-prerequisites)) |
| `ERROR Docker is not running, or your user cannot use it` | Daemon stopped, or your user is not in the `docker` group | `sudo systemctl start docker`; `sudo usermod -aG docker $USER`, then log out and in |
| `ERROR Docker Compose v2 not found` | Old `docker-compose` v1 only | Install the Compose v2 plugin (`docker compose version`) |
| `ERROR Docker Compose X is too old; Flutter OTA System needs Compose v2.20 or newer.` | Old Compose plugin | Update Docker / the Compose plugin |
| `ERROR Required files are missing.` | Incomplete clone or download | Clone the repository again with `git clone` |
| `ERROR .env not found. Run: ./flutter-ota-system.sh setup …` | No `.env` (a script other than `setup` was run first) | `./flutter-ota-system.sh setup` |
| `ERROR OTA_ENV=production in .env` | The local scripts refuse production settings | Use `OTA_ENV=development` locally |
| `Port 8000 (FLUTTER_OTA_API_PORT) is already in use on this computer.` | Another program (or another Flutter OTA System stack) uses the port | Stop it, or choose other ports ([self-hosting](self-hosting.md#ports-are-taken-or-a-second-stack)) |
| `port is already allocated` / `address already in use` | Same, detected by Docker | As above, then `./flutter-ota-system.sh up` |
| `ERROR The stack did not become healthy.` | A container failed its health check | `./flutter-ota-system.sh logs api` (or `postgres`); see the next rows |
| `api` stays unhealthy; logs show `Signing key not found: /data/keys/ota_signing_private.pem` | No signing key and `OTA_AUTO_GENERATE_SIGNING_KEY=false` | `./flutter-ota-system.sh up` (creates it if missing; never replaces one) |
| `api` logs `password authentication failed for user "flutter_ota"` | `POSTGRES_PASSWORD` in `.env` differs from the one the database volume was created with (for example `.env` was deleted and re-created) | Put the old `.env` back (a `./flutter-ota-system.sh backup` folder has a copy as `env`), or `./flutter-ota-system.sh reset` to start fresh |
| `WARN Database volume … already exists: keeping the example POSTGRES_PASSWORD.` | `setup` created a new `.env` while old data still exists | As above if the API then cannot log in |
| `.env` change has no effect | Containers keep old values | `./flutter-ota-system.sh up` (recreates changed services) |
| `[FAIL]` lines from `verify_demo.sh` | A step of the pipeline failed | Run `./flutter-ota-system.sh demo` (seeds and publishes first); read `./flutter-ota-system.sh logs api` |
| `ERROR CLI not installed. Run ./flutter-ota-system.sh cli first.` | `./flutter-ota-system.sh ota` without the CLI | `./flutter-ota-system.sh cli` |
| `ERROR python3 venv module missing` | Ubuntu without `python3-venv` | `sudo apt install -y python3-venv` |
| `ERROR Checksum mismatch in <dir>: the backup is damaged` | A backup file changed after it was written | Use another backup |
| The app downloads nothing; `failed` with a connection error to `…:8080` | `OTA_CDN_BASE_URL` points at an address the device cannot reach, or `adb reverse` is missing for the file-server port | Fix `OTA_CDN_BASE_URL` ([configuration.md](configuration.md#which-ota_cdn_base_url)) and run `adb reverse tcp:8080 tcp:8080` for a USB phone |

## Backend connection failures

| Symptom | Cause | Diagnose | Fix |
|---|---|---|---|
| CLI: `httpx.ConnectError` / connection refused | Wrong `OTA_API_URL`, or the API is down | `curl $OTA_API_URL/health/ready` | Start the stack; fix `OTA_API_URL` |
| CLI: `error 401: Invalid or missing X-API-Key` | `OTA_API_KEY` missing or different from the server's `OTA_ADMIN_API_KEY` | Compare with `.env` / `deploy/.env` | `export OTA_API_KEY=…` |
| App: `failed`, `Connection refused` / timeout | The device cannot reach `OTA_SERVER_URL` | Open `<server>/health/ready` in the phone's browser | Emulator: use `10.0.2.2`, not `localhost`. USB phone, debug build: `adb reverse tcp:8000 tcp:8000` (and the CDN port) with `http://localhost:8000`; release builds need `https://`. Wi-Fi phone: an `https://` address only (plain `http://` to a LAN IP is refused); same Wi-Fi; firewall |
| App: `failed` with a cleartext / `CLEARTEXT communication not permitted` error | Android blocks plain `http://` | — | Use HTTPS, or (test builds only) `android:usesCleartextTraffic="true"` |
| App: `failed` with `insecure URL … release builds require https://` or `… only allowed for localhost or the Android emulator` | Release builds accept `https://` only; debug builds also allow `http://localhost` and `http://10.0.2.2` | Check `OTA_SERVER_URL` and the build mode | Use `https://`; for local tests, a debug build with `adb reverse` and `http://localhost:8000` |
| App: `rejected` with `insecure URL …`, `unsupported URL scheme` or `insecure redirect … downgrades are never followed` | The download URL (`OTA_CDN_BASE_URL`), or a redirect from it, uses plain `http://` where it is not allowed | Check `OTA_CDN_BASE_URL` in `.env`; `curl -I` the patch URL to see redirects | Use `https://` everywhere (and no https→http redirects); debug builds only: `http://localhost:8080/cdn` with `adb reverse` |
| Code patch reported active, but the app still behaves like the store build | The Flutter version may ignore or refuse the `--aot-shared-library-name` path; the store code then runs while the client reports the patch | Compare a visible change, not just the patch number; check `logcat` | Test each Flutter version  |
| App: `rejected` with `invalid patch id` | The update-check response named a patch id that is not a lowercase UUID | Compare the server version; check for a proxy rewriting responses | Use an unmodified Flutter OTA System server |
| App: `failed` with `TimeoutException` (`no response`, `download stalled`, `download too slow`) | The server or file server stopped answering, or the download took over 10 minutes | Open the patch URL in the phone's browser | Fix the server/CDN; the next check retries |
| Server won't start: `Unsafe production settings:` + list | `OTA_ENV=production` with unsafe values | `docker compose logs api` | Fix each listed setting ([configuration.md](configuration.md#production-safety-checks)) |

## Device registration failures

| Message | Cause | Fix |
|---|---|---|
| `register failed: HTTP 404 {"detail":"Unknown application"}` | `appSlug` does not exist on this server | `ota app list`; create the app or fix the slug |
| `register failed: HTTP 422 …` | Invalid field, e.g. a slug with capitals or an unusual arch value | Check the rules in [api-reference.md](api-reference.md#register-a-device) |
| Device registered, but the admin page shows nothing | The summary groups by each device's **last check** | Make the app call `checkForUpdate()`; refresh the page |

## Update-check failures ("the phone never gets the patch")

Go through this list in order:

1. **Release unknown.** `releaseVersion` must equal the registered version exactly (`1.0.0+1`).
   `ota release list <app>` shows the registered versions. An unknown version always gets "no
   update".
2. **Wrong channel.** The device uses its build's `OTA_CHANNEL` (default `production`) or the
   value from `setChannel`. `ota patch list` shows where the patch is deployed.
3. **Not in the rollout.** At less than 100%, only some devices are included.
4. **No file for this arch.** Emulators are usually `x86_64`, phones `arm64-v8a`. `ota patch show
   <id>` lists the artifacts.
5. **Format not supported.** `MockPatchRuntime` supports only `mock-v1`. `AotPatchRuntime`
   supports `aot-bidiff-android-v1` **only in Android release builds**; in debug builds it
   supports nothing, so code patches are never offered.
6. **Checked recently.** Without `force: true`, a check within the server's interval returns
   `upToDate` with `checked recently`.
7. **Not published.** Drafts are never offered: `ota patch publish <id> --channel … --percent …`.
8. **Policy gate.** Publishing failed with `403 policy_review_required` for a `public_store` app:
   `ota app approve-policy <app> --reason "…"`.

You can reproduce what the server decides with the same query the app sends
([api-reference.md](api-reference.md#check-for-an-update)).

## The app refuses a patch

`checkForUpdate()` returns `rejected` with one of these messages:

| Message | Cause | Fix |
|---|---|---|
| `unknown signing key <id>` | The app does not trust the key that signed the patch (e.g. built with a dev key, or the server's key changed) | Rebuild the app with the server's key from `ota key show`. After `cleanup_local.sh`, the local key is new |
| `signature invalid` | The metadata does not match the signature: wrong key data in the app, a modified response, or a mismatch in platform/arch | Check `OTA_PUBLIC_KEY`; use HTTPS; compare `ota key show` |
| `download size mismatch` | The file on the server differs from the signed size (truncated, replaced or proxied) | Re-upload as a new patch; check the file server or CDN |
| `hash mismatch` | The file's SHA-256 differs from the signed hash | As above. Never edit files under `patches/` |
| `replay: patch N is not newer than M` | The device already accepted a higher patch number | Publish a newer patch, or roll back the newer one so the server offers N as the rollback target |
| `patch previously failed on this device` | It crashed here before | Fix it in a new patch |
| `arch mismatch`, `runtime abi mismatch`, `unsupported format` | Patch made for another build type (e.g. a `mock-v1` release patched for a code-patch app) | Patch the right release; code-patch releases must come from `ota release android` |
| `release id changed` | The server answered with a release id this install retired earlier (a deleted and re-created release id going back), or the app uses `ota_client` older than this fix and the release was deleted and created again | Current `ota_client` switches to a re-created release by itself and drops the old patches (KI-1, fixed). Older builds: reinstall the app. Prefer a new build number over re-creating a version |
| `application id mismatch` | `OtaConfig.applicationId` is not this app's server id (or `OTA_APPLICATION_ID` was not set) | Use the `"id"` from `ota app list` (not the slug, not the Android package name) |

`failed` (not `rejected`) with `download failed: HTTP 404` means the file server cannot find the
file: check `OTA_CDN_BASE_URL` and that the file server shares the storage volume or bucket.

## Hash mismatches for code patches

| Message (`failed`) | Cause | Fix |
|---|---|---|
| `this patch was built for a different store build (base hash mismatch)` | The installed APK/AAB is not the build registered as the release (rebuilt, or installed with `flutter run`) | Install exactly the file `ota release android` printed, or register the installed build as a new release |
| `rebuilt code does not match the signed hash` | The diff did not rebuild the expected file | Rebuild the patch with `ota patch android`; report it if it repeats |
| `code patches need a release build on Android` | Debug build | Use a release build |
| `store libapp.so not found` | Unusual APK/AAB layout or ABI | Check `adb logcat`; report it with the device ABI |

## Patch activation failures

| Symptom | Cause | Fix |
|---|---|---|
| Patch staged, but the old code still runs | Patches run on the **next** start | Close the app fully (swipe it away) and open it again |
| Patch appears, then is gone after the next start | It was not confirmed: it crashed, or the app was closed before `markBootSuccessful` ran (default helper: 5 s after start) | Admin page **Boot failed**; `adb logcat` shows `Patch <id> did not confirm its last start: skipping it`. Fix the crash, or keep the app open longer when testing |
| `OTA boot failed, running the store code` in logcat | Unexpected error in the native boot hook | Read the stack trace in logcat; the app safely runs its store code |
| `Patch <id> failed verification: skipping it` in logcat | The patched `libapp.so` on disk changed or is incomplete | Nothing to do: the device skips it. A new patch will be downloaded fresh |
| Code patch never activates in a `flutter run` session | Debug builds run Dart in JIT mode | Test with a release build of the registered release |

## Flutter and engine compatibility (original alpha code patches)

| Message | Cause | Fix |
|---|---|---|
| `error: Flutter changed (A → B). A patch must use the exact Flutter the release used.` | Your Flutter SDK differs from the release's | Switch to the release's Flutter version (`ota release list` shows `flutter_version`), e.g. with `git checkout` in the Flutter SDK or a version manager |
| `error: this change needs a store release, a patch can only change Dart code:` + list | Native libs, `.dex`, manifest or resources changed | Revert those changes, or ship a new store release |
| `error: assets changed, and a patch can only change Dart code:` + list | Images, fonts, `.env` or other assets changed. If `MaterialIcons` is listed, the release was built with icon tree-shaking | Revert, or make a new release (keep the default `--no-tree-shake-icons`) |
| ``error: release X was not made with `ota release android`, so it can't take code patches`` | The release was created with `ota release create` | Register the build with `ota release android` |
| ``error: no android release X for 'app'. Run `ota release android` first.`` | Version in `pubspec.yaml` not registered | Register it, or pass `--release` |
| `Nothing to patch: the Dart code is identical to the release.` | No Dart change | — |
| `error: <file> has no lib/<abi>/libapp.so. Is it a release build?` | Debug or unusual build | Build a release APK/AAB |

Every Flutter upgrade needs a new store release. Code patches depend on Flutter's loader
internals and have only been tested with the Flutter versions the maintainers used.

## CLI and admin errors

| Message | Cause | Fix |
|---|---|---|
| `error 409: Release android X already exists` | Version registered before | Delete the test release (`ota release delete`) or bump the build number |
| `error 409: N device(s) still report android X from a deleted release…` | You deleted a release that devices use and are registering the same version again | Prefer a new build number. To re-use the version, pass `--replace`: those installs drop the old release's patches |
| `error 409: promotion_checks_failed: patch #N: …` | Raising a patch on `production` that was not tested on another channel, or that has boot failures | Publish it to `staging` and test it first. To override on purpose: `--force --reason "…"` (logged). A patch created with `--channel production` stays a draft; its id was printed |
| `error 409: Roll back or revoke its published patches first` | Deleting a release with live patches | Roll back or revoke them first |
| `error 409: Cannot publish a revoked patch` | Revoked patches are final | Create a new patch |
| `error 409: Only published patches have a rollout` | `rollout` on a draft or rolled-back patch | `ota patch publish` first |
| `error: patch #N is not on 'staging'. Test it there first, or pass --force` | `promote` safety check | Publish to staging and test first |
| `error: patch #N has K boot failure(s). Fix or pass --force` | `promote` safety check | Investigate before promoting |
| `error 403: policy_review_required: …` | Code patch for a `public_store` app without approval | `ota app approve-policy <app> --reason "…"` |
| `error 422: Upload the release's base <arch> artifact before an AOT patch` | Code-patch upload without the release's base file | Use `ota release android` / `ota patch android` |

## Database problems

| Symptom | Cause | Fix |
|---|---|---|
| `/health/ready` fails; API logs show connection errors | Postgres down or wrong `OTA_DATABASE_URL` | `docker compose ps postgres`; `docker compose logs postgres`; fix the URL |
| `psql: FATAL: role "ota" does not exist` locally | The local stack's user is `flutter_ota` (the single-server deploy uses `ota`) | `./flutter-ota-system.sh psql` (or `docker compose exec postgres psql -U flutter_ota -d flutter_ota`) |
| `psql: … connection refused` on `localhost:5432` from your computer | Postgres has no host port by default | Use `./flutter-ota-system.sh psql`, or enable the port ([self-hosting](self-hosting.md#postgres-from-your-computer-optional)) |
| Errors about too many connections on a small managed Postgres | Pool size × workers is too high | Lower `OTA_DB_POOL_SIZE` and/or `WEB_CONCURRENCY` |
| Migration errors at startup | Schema changed by hand, or a downgrade | Restore from backup; never edit the schema by hand |

## Problems on iOS, macOS or Windows

Flutter OTA System has been tested internally only on a **Linux** development machine and with **Android**
apps ([testing status](limitations.md#compatibility)). iOS, macOS and Windows
are **not tested**, so problems there may have no entry on this page. Differences you may hit:
other commands to find your computer's IP, Docker Desktop networking, and file paths. iOS code
patches are not implemented. If you find a fix, please report it (see
[CONTRIBUTING.md](../CONTRIBUTING.md)).

## Still stuck?

Search or open an issue with your host OS, app platform, versions, steps and logs, **with secrets removed**. Security
problems go through [SECURITY.md](../SECURITY.md), never public issues.
