# Shot 2: redirect patches on a real phone

One long run on a real Android phone, with the real CLI, server, signing, download, verifier
process and bytecode interpreter. It answers, in one combined report:

| # | Question | How |
|---|---|---|
| 1 | Does a store build prepared by the redirect engine behave **exactly like v1**? | All 53 test cases, compared with the same code run locally |
| 2 | Does a patch v1 → v2 build, upload, download, verify and run, and behave **like v2**? | All cases after the patch |
| 3 | What does it cost? | Start-up, memory, speed of unchanged code and sizes, compared with a `stock` build (no OTA) and a `plain` OTA build (no checks) |
| 4 | Does patch size follow the size of the change? | Patches for a one-line change, body changes, signature changes and structure changes (levels 1–3) |
| 5 | Do patches chain and roll back correctly? | Patch 2 on top of patch 1, then `flutter_ota rollback` of patch 2 |
| 6 | Does crash protection work for redirect patches? | A patch with an uncaught Dart error, and a patch that ends the process |
| 7 | Which background isolates miss the patch (known limit H4)? | `Isolate.run` with a closure and with a top-level function (what `compute()` does), and `Isolate.spawn` |
| 8 | What does the dynamic interface cost? | The same store build with an EXPERIMENTAL app-only interface |

## You need

- The Linux x64 build machine, set up as in [docs/quick-start.md](../../../docs/quick-start.md)
  steps 1–2: a running server and an app created on it. Note the app's **id** (a UUID).
- An arm64 Android phone with USB debugging, connected (`adb devices` lists it).
- `adb`, `python3`, `unzip`, `perl`, and `dart` on `PATH` (any Dart 3.8+, used once to activate
  the CLI of this checkout). If `dart` is a wrapper that fails in scripts (the snap package exits
  with code 255 there), point `CLI_DART` at the `dart` binary of an SDK folder, for example
  `CLI_DART=~/snap/flutter/common/flutter/bin/dart`.
- About 10 GB free disk the first time, as in the quick start (toolchain and Android build tools,
  kept in the cache), and about 1 GB per full run after that.

## Run

```bash
git fetch origin && git checkout prototype/adaptive-patch-levels && git pull
cd prototypes/redirect_stubs/shot2

export APP_ID=<server app UUID>
export FLUTTER_OTA_ADMIN_KEY=<server admin key>

./run_shot2.sh all        # every mode in turn, then one combined report (about 90 minutes)
```

Keep the phone connected and unlocked with the screen on, and don't use it during the run.

One mode at a time also works: `./run_shot2.sh <mode>`.

| Mode | Store build | Then |
|---|---|---|
| `stock` | plain `flutter build apk`: no OTA, no dynamic interface | measures only |
| `plain` | the feature engine: OTA with the full interface, no checks | measures only |
| `redirect-narrow` | redirect, tiny leaves without checks, EXPERIMENTAL app-only interface | patch v1 → v2 |
| `redirect` | redirect, a check in every function | patch v1 → v2 |
| `redirect-fast` | redirect, tiny leaves without checks (`--skip-leaves`) | patch v1 → v2, patch chain + rollback, two bad patches, patch size ladder |

Each mode makes a new store release with its own build number, uninstalls the app
`dev.example.ota_shot2`, and installs its own build. A stage that fails (for example the
narrowed interface rejecting a patch) is written to `failures.txt`, and the run goes on with the
next stage, so one run always collects as much as it can.

The script:
- activates the `flutter_ota` CLI of this checkout (`dart pub global activate --source path`);
- creates the test app once in `.local/ota_shot2/app` of this checkout (git-ignored; template in
  `app/`, the cases from `../cases/v1`), installs the toolchain and creates the signing keys. The
  app must live inside the checkout: the CLI needs it and `packages/ota_client` (a path
  dependency) in one workspace folder;
- uses `http://localhost:8000` and `adb reverse`, so the phone reaches a server on this machine.
  Another server: `SERVER_URL=https://...` (release builds accept only HTTPS, except localhost).

Options: `WORK=<folder inside the checkout>` (default `.local/ota_shot2`), `CLI_DART=<dart>`,
`STARTS=<n>` cold starts per state (default 5), `ANDROID_SERIAL=<serial>` with several phones.

**Second phone.** Run `all` again with `ANDROID_SERIAL=<serial of the other phone>`. The
combined report shows each phone in its own section. A low-end or Samsung phone is the most
useful second phone.

## Results

`.local/ota_shot2/results/` in the checkout:

| File | What |
|---|---|
| `combined-<time>.md` | **The one report to read**: all modes side by side, per phone |
| `<mode>-<time>/report.md` | The details of one mode |
| `<mode>-<time>/summary.json` | Its numbers (the combined report is built from these) |
| `<mode>-<time>/failures.txt` | Stages that failed, if any |
| `release.log`, `patch*.log`, `rollback.log`, `ladder_*.log` | CLI output |
| `*.log`, `*.epoch.log`, `*.meminfo.txt` | Phone log lines and memory of each start |
| `oracle_v1.txt`, `oracle_v2.txt`, `oracle_v3.txt` | Expected values: the cases run locally with the toolchain's Dart |
| `patch*.json`, `ladder_*.json` | Patch summaries: manifest, the tool's decisions and metrics |
| `dynamic_interface.yaml` | The interface of that store build |
| `apk/` | The store APK of that mode |

Send back the whole `results/` folder; it contains no keys. Never send `~/.config/flutter_ota/`.

**Other phones.** The APKs in `apk/` work on any arm64 phone, but they get patches only if they
reach the server: build them with `SERVER_URL` set to an HTTPS address those phones can reach.

## Pass conditions

| Check | Pass |
|---|---|
| Store build = v1, every mode | 53 / 53 |
| Patched = v2 | 0 unexpected differences (background-isolate cases are listed separately) |
| Patch chain | Patch 2 = v3; after the rollback the phone runs patch 1 again and equals v2 |
| Process-crash patch | Rolled back after 2 crashed starts; the phone returns to the previous patch |
| Start-up with a patch | Under 300 ms more than without |
| Check cost (`redirect-fast` vs `plain`, same phone) | ≤ 3% in `mixed_app_logic` |
| Patch size | Grows with the change: a one-line patch is a few KB |

Expected findings, not failures:
- **Dart-error patch is not rolled back:** the SDK counts Dart errors only after a feature slot of the old engine was used. The run documents this gap.
- **Background isolates run the store code** (H4).
- **`redirect-narrow` may fail to build its patch** if the patch needs a library outside the app.

## If something fails

- `patch.log` ends in `dart2bytecode failed`: the module uses something the dynamic interface of
  the store build does not allow. Send `patch.log` and `dynamic_interface.yaml`.
- A patched start shows `status=storeCode`: send `run2_download*.log` and the `*.full.log` of
  that start, if the script stopped there. The verifier process logs under the tag `flutter`
  too.
- `ota_redirect` fails during `release`: the tool runs with the toolchain's Dart and fetches its
  own dependencies once (`prototypes/redirect_stubs/tool`), which needs network access.
