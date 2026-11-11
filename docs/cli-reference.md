# CLI reference (`ota`)

The `ota` command-line tool ([`cli/ota.py`](../cli/ota.py)) calls the [admin API](api-reference.md#admin-api).
Install it as shown in [installation.md](installation.md#7-install-the-ota-cli):

```bash
python3 -m venv .venv && .venv/bin/pip install -r cli/requirements.txt
alias ota="$PWD/.venv/bin/python $PWD/cli/ota.py"
export OTA_API_URL=http://localhost:8000          # default http://127.0.0.1:8000
export OTA_API_KEY=<the server's OTA_ADMIN_API_KEY>
```

Or build and install it as a local package (not on PyPI): `./scripts/build_cli.sh`, then
`pip install cli/dist/punit_cli-0.1.0a0-py3-none-any.whl` into a virtual environment
([installation.md](installation.md#7-install-the-ota-cli)). The package needs Python 3.10+ and
pins `bsdiff4` to `>=1.4.0,<1.4.2` ([KI-7](known-issues.md#ki-7-the-cli-breaks-with-bsdiff4-142)).

Every command prints JSON (or a table for `patch list`). On an API error it prints
`error <HTTP status>: <detail>` and exits with a non-zero code. `ota <group> <command> --help`
shows the options.

Arguments after `--` are passed unchanged to `flutter build` (only used by the `android`
commands).

## `ota app`

| Command | Purpose |
|---|---|
| `ota app create <slug> "<name>" [--distribution enterprise\|public_store]` | Create an application with channels `dev`, `staging`, `production`. Default distribution `enterprise` |
| `ota app list` | List applications |
| `ota app approve-policy <slug> --reason "<text>" [--revoke]` | Record (or with `--revoke`, withdraw) the policy approval needed to publish Android code patches to a `public_store` app. The reason and time are stored ([KI-2](known-issues.md#ki-2-the-policy-approval-reason-is-not-stored), fixed) |
| `ota app policy-history <slug>` | Every approval and withdrawal with its reason and time, newest first |

## `ota release`

| Command | Purpose |
|---|---|
| `ota release android <app> [--project DIR] [--kind aab\|apk] [--artifact FILE] [--tree-shake-icons] [--replace] -- <flutter build args>` | Build (or take `--artifact`) a release APK/AAB, register it, upload its `libapp.so` per ABI and its fingerprint. For Android code patches. Default `--kind aab`, `--project .`. `--replace`: see below |
| `ota release create <app> --platform android\|ios --version <x.y.z+n> [--flutter-version V] [--engine-revision R] [--runtime-abi ABI] [--base ARCH=PATH]… [--replace]` | Register a release manually (e.g. for `mock-v1`). Default runtime ABI `ota-runtime-v1`. `--replace` registers a version again that devices still report from a deleted release: their old patches are dropped ([KI-1](known-issues.md#ki-1-re-creating-a-deleted-release-breaks-existing-installs)) |
| `ota release list <app>` | List releases with their artifacts and fingerprints |
| `ota release delete <app> --version <v> [--platform android\|ios]` | Delete a release and its patches. Refused while a patch is published |

## `ota patch`

| Command | Purpose |
|---|---|
| `ota patch android <app> [--project DIR] [--release V] [--artifact FILE] [--channel C] [--percent P] [--note T] [--allow-native-diffs] [--allow-asset-diffs]` | Rebuild the app with the release's build args, refuse non-Dart changes, diff each ABI, upload. Publishes when `--channel` is given (default 100%), else leaves a draft |
| `ota patch create <app> --platform P --release V --file ARCH=PATH… [--format F] [--result-sha256 H] [--note T] [--channel C] [--percent P]` | Create a patch from files you provide. Default format `mock-v1`. `--result-sha256` is required for `aot-bidiff-android-v1` |
| `ota patch list <app> --platform P --release V` | One line per patch: number, status, format, deployments, id |
| `ota patch show <patch_id>` | Full patch JSON, including `event_counts` |
| `ota patch publish <patch_id> --channel C --percent P [--force --reason R]` | Publish a `draft` or `rolled_back` patch to a channel |
| `ota patch rollout <patch_id> --channel C --percent P [--force --reason R]` | Set the rollout of a published patch on a channel (adds the channel if needed) |
| `ota patch promote <patch_id> [--from staging] [--to production] [--percent 100] [--force --reason R]` | Copy a tested patch to another channel. Refuses unless it is live on `--from` and has no boot failures; `--force --reason` skips both checks (the server logs the reason) |
| `ota patch rollback <patch_id>` | Mark a published patch `rolled_back` |
| `ota patch revoke <patch_id> [--yes]` | Permanently revoke. Asks you to type `revoke` unless `--yes` |

Example output of `ota patch list`:

```
#1   published    mock-v1                dev=100%                       b1d78a59-3871-42d3-ad7b-fa26cb07b603
#2   revoked      mock-v1                dev=100%                       54702757-62d7-44af-a69b-60b354385153
```

**Promotion checks.** The server enforces them for protected channels (`OTA_PROTECTED_CHANNELS`,
default `production`), whichever command or tool you use: raising a patch's percentage there needs
an earlier deployment on another channel (e.g. `staging`) and no reported boot failures. Otherwise
`publish`, `rollout`, `promote`, and `patch create`/`patch android` with `--channel production`
fail with `error 409: promotion_checks_failed: …`; a newly created patch then stays a **draft**
(its id is printed before publishing). Publish it to `staging` first, or override with
`--force --reason "…"` on `publish`, `rollout` or `promote`. Lowering a percentage is never
blocked. `promote` also checks in the CLI first, for a clearer message
([KI-4](known-issues.md#ki-4-promote-safety-checks-are-enforced-only-by-the-cli), fixed).

## `ota key`

| Command | Purpose |
|---|---|
| `ota key show` | Print the public signing key (`key_id`, `algorithm`, `uncompressed_point_base64`, `pem`) |
| `ota key show --dart` | Print it as a Dart constant: `const otaPublicKeys = {'<key_id>': '<point>'};` |

## Server-side key tool

Run inside the API environment, not through `ota`:

| Command | Purpose |
|---|---|
| `python -m app.keygen` | Create the signing key file at `OTA_SIGNING_KEY_PATH` (refuses to overwrite). Prints `OTA_PUBLIC_KEY for the apps: <id>:<point>` |
| `python -m app.keygen --pem` | Generate a key and print it as a one-line `OTA_SIGNING_KEY_PEM` value, plus the public key. Writes no file |

## Local scripts

| Script | Purpose |
|---|---|
| `./scripts/setup_local.sh` | Build the image, create the dev signing key, start the local stack |
| `./scripts/generate_dev_signing_key.sh` | Create the dev signing key in volume `punit_keys` (never replaces one) |
| `./scripts/seed_demo.sh` | Create `punit-demo`, its channel and release; print the app's `--dart-define`s |
| `./scripts/publish_test_patch.sh` | Publish a signed `mock-v1` test patch to `dev` at 100% |
| `./scripts/verify_demo.sh` | End-to-end checks; exits non-zero on failure |
| `./scripts/cleanup_local.sh [--yes \| --keep-data]` | Remove the stack and its volumes (asks first). `--keep-data` stops it without deleting data |
| `./scripts/build_cli.sh` | Build the `ota` CLI as a wheel and sdist in `cli/dist/` (local only; nothing is uploaded) |
| `./scripts/prepublish_check.sh [--no-e2e]` | Maintainers: secret scan, required files, tests, demo |
| `python scripts/simulate_fleet.py --app A --release V [--channel C] [--arch A] [--devices N]` | Register N fake devices and count which patch each is offered |
