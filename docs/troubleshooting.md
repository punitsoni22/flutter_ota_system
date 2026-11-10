# Troubleshooting

Each entry gives the **cause**, how to **diagnose** it and how to **fix** it. The messages are the
exact texts printed by the server, the CLI, the client or the scripts.

**First steps for any problem**

```bash
curl http://localhost:8000/health/ready        # {"status":"ok"}? (use your server URL)
docker compose ps                              # all services "(healthy)"?
docker compose logs --tail=100 api             # server errors
adb logcat | grep -E "OtaBoot|OTA:"            # Android device side
```

In the app, log the `UpdateResult` returned by `checkForUpdate()`: its `status` and `message`
tell you which step failed ([flutter-integration.md](flutter-integration.md#5-handle-results-and-errors)).

## Docker and the local stack

| Message / symptom | Cause | Fix |
|---|---|---|
| `ERROR docker not found. Install Docker Engine or Docker Desktop.` | Docker is not installed | Install it ([installation.md](installation.md#1-prerequisites)) |
| `ERROR Docker is not running, or your user cannot use it` | Daemon stopped, or your user is not in the `docker` group | `sudo systemctl start docker`; `sudo usermod -aG docker $USER`, then log out and in |
| `ERROR Docker Compose v2 not found` | Old `docker-compose` v1 only | Install the Compose v2 plugin (`docker compose version`) |
| `ERROR .env not found. Run: cp .env.example .env` | No `.env` | `cp .env.example .env` |
| `ERROR OTA_ENV=production in .env` | The local scripts refuse production settings | Use `OTA_ENV=development` locally |
| `port is already allocated` / `address already in use` | Port 8000, 8080 or 5432 is taken | Change `PUNIT_API_PORT`, `PUNIT_CDN_PORT` or `PUNIT_POSTGRES_PORT` in `.env`, then `docker compose up -d` |
| `api` stays unhealthy; logs show `Signing key not found: /data/keys/ota_signing_private.pem` | No signing key and `OTA_AUTO_GENERATE_SIGNING_KEY=false` | `./scripts/generate_dev_signing_key.sh`, then `docker compose up -d` |
| `.env` change has no effect | Containers keep old values | `docker compose up -d` (recreates changed services) |
| `[FAIL]` lines from `verify_demo.sh` | A step of the pipeline failed | Run `seed_demo.sh` and `publish_test_patch.sh` first; read `docker compose logs api` |

## Backend connection failures

| Symptom | Cause | Diagnose | Fix |
|---|---|---|---|
| CLI: `httpx.ConnectError` / connection refused | Wrong `OTA_API_URL`, or the API is down | `curl $OTA_API_URL/health/ready` | Start the stack; fix `OTA_API_URL` |
| CLI: `error 401: Invalid or missing X-API-Key` | `OTA_API_KEY` missing or different from the server's `OTA_ADMIN_API_KEY` | Compare with `.env` / `deploy/.env` | `export OTA_API_KEY=…` |
| App: `failed`, `Connection refused` / timeout | The device cannot reach `OTA_SERVER_URL` | Open `<server>/health/ready` in the phone's browser | Emulator: use `10.0.2.2`, not `localhost`. Phone: computer's LAN IP and `PUNIT_BIND_ADDRESS=0.0.0.0`; same Wi-Fi; firewall |
| App: `failed` with a cleartext / `CLEARTEXT communication not permitted` error | Android blocks plain `http://` | — | Use HTTPS, or (test builds only) `android:usesCleartextTraffic="true"` |
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
| `release id changed` | The release was **deleted and created again** with the same version, so this install remembers the old release id | Known bug ([KI-1](known-issues.md#ki-1-re-creating-a-deleted-release-breaks-existing-installs)): reinstall the app, or register a new build number instead of re-creating a version |
| `application id mismatch` | `OtaConfig.applicationId` is pinned to another app | Fix the pinned id |

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

## Flutter and engine compatibility

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
| `error 409: Release android X already exists` | Version registered before | Delete the test release (`ota release delete`) or bump the build number. Note the `release id changed` issue above for existing installs |
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
| `psql: FATAL: role "ota" does not exist` locally | The local stack's user is `punit` (the single-server deploy uses `ota`) | `docker compose exec postgres psql -U punit -d punit` |
| Errors about too many connections on a small managed Postgres | Pool size × workers is too high | Lower `OTA_DB_POOL_SIZE` and/or `WEB_CONCURRENCY` |
| Migration errors at startup | Schema changed by hand, or a downgrade | Restore from backup; never edit the schema by hand |

## Still stuck?

Search or open an issue with versions, steps and logs, **with secrets removed**. Security
problems go through [SECURITY.md](../SECURITY.md), never public issues.
