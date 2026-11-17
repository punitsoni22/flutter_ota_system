# Shot 2: redirect patches on a real phone

One run on a real Android phone. It proves what Shot 1 proved locally, this time with the real
CLI, server, signing, download, verifier process and bytecode interpreter:

1. A store build prepared by the redirect engine behaves **exactly like v1** (51 cases).
2. A patch made from the v1 → v2 change is built, guarded, compiled, verified, signed and
   uploaded by `flutter_ota patch android`; the phone downloads it, verifies it and runs it at
   the next start.
3. The patched app behaves **like v2**. The only expected difference is `c43_isolate`: code in a
   background isolate has its own slots (known limit H4, measured here).
4. Numbers: start-up with and without a patch, the cost of the checks in unchanged code,
   APK / `libapp.so` / patch sizes, patch level and changed lines.

## You need

- The Linux x64 build machine, set up as in [docs/quick-start.md](../../../docs/quick-start.md)
  steps 1–2: a running server and an app created on it. Note the app's **id** (a UUID).
- An arm64 Android phone with USB debugging, connected (`adb devices` lists it).
- `adb`, `python3`, `unzip`, `perl`, and `dart` on `PATH` (any Dart 3.8+, used once to activate
  the CLI of this checkout).
- About 10 GB free disk the first time, as in the quick start (toolchain and Android build tools,
  kept in the cache), and a few hundred MB per run after that.

## Run

```bash
git fetch origin && git checkout prototype/adaptive-patch-levels
cd prototypes/redirect_stubs/shot2

export APP_ID=<server app UUID>
export FLUTTER_OTA_ADMIN_KEY=<server admin key>

./run_shot2.sh plain           # baseline store build (feature engine, no checks); no patch
./run_shot2.sh redirect        # every function has a check; full patch cycle
./run_shot2.sh redirect-fast   # tiny leaf functions have no check; full patch cycle
```

Each run makes a new store release with its own build number, installs it (the app
`dev.example.ota_shot2` is uninstalled first), and takes about 10–20 minutes. Run all three on the
same phone: the `plain` run is what the other two are compared with.

The script:
- activates the `flutter_ota` CLI of this checkout (`dart pub global activate --source path`);
- creates the test app once in `~/ota_shot2/app` (template in `app/`, the cases from
  `../cases/v1`), installs the toolchain and creates the signing keys;
- uses `http://localhost:8000` and `adb reverse`, so the phone reaches a server on this machine.
  Another server: `SERVER_URL=https://...` (release builds accept only HTTPS, except localhost).

Options: `WORK=<folder>` (default `~/ota_shot2`), `STARTS=<n>` cold starts per state (default 5),
`ANDROID_SERIAL=<serial>` with several phones.

## Results

Each run writes `~/ota_shot2/results/<mode>-<time>/`:

| File | What |
|---|---|
| `report.md` | The summary: pass/fail per point above, numbers |
| `summary.json` | The same numbers, for comparing modes and phones |
| `release.log`, `patch.log` | CLI output |
| `run1_store.log` … `run4_patched_bench.log` | Phone log lines of each start (`[shot2] ...`) |
| `oracle_v1.txt`, `oracle_v2.txt` | The cases run locally with the toolchain's Dart (expected values) |
| `patch.json` | Patch summary: manifest, the tool's decisions and metrics |
| `apk/` | The store APK of this run |

Send back the three results folders (they contain no keys). Never send `~/.config/flutter_ota/`.

**Other phones.** The APK in `apk/` works on any arm64 phone, but it gets patches only if it
reaches the server: build it with `SERVER_URL` set to an HTTPS address those phones can reach.

## Pass conditions

| Check | Pass |
|---|---|
| Store build = v1 | 51 / 51 |
| Patched = v2 | 50 / 51, the only difference `c43_isolate` (or 51 / 51) |
| Patch status at the second start after publishing | `patched` |
| Start-up with a patch | under 300 ms more than without |
| Check cost (`redirect` vs `plain`, same phone) | within the budget (≤ 3%) in `mixed_app_logic`; the tiny-function benches show the worst case |
| Patch size | KB, not MB |

## If something fails

- `patch.log` ends in `dart2bytecode failed`: the module uses something the dynamic interface
  of the store build does not allow. Send `patch.log` and `patch.json`.
- The patched start shows `status=storeCode`: send `run2_download.log` and the full
  `logcat` of that start (`*.full.log` if the script stopped there). The verifier process logs
  under the tag `flutter` too.
- `ota_redirect` fails during `release`: the tool runs with the toolchain's Dart and fetches its
  own dependencies once (`prototypes/redirect_stubs/tool`), which needs network access.
