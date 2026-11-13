# CLI reference

Flutter OTA System has two command-line tools:

| Tool | Who uses it | What it does |
| --- | --- | --- |
| [`flutter_ota`](#flutter_ota) (Dart, `packages/flutter_ota_cli`) | App developers | Toolchain, keys, store release, patches, status, rollback (bytecode architecture) |
| [`ota`](#admin-cli-ota) (Python, `cli/`) | Server operators | Apps, channels, promotion, revocation; the [original alpha](releases-and-patches.md#original-alpha-patch-formats) patch flow |

The local server stack is driven by `./flutter-ota-system.sh` (see [self-hosting](self-hosting.md)).

## `flutter_ota`

Experimental alpha. It runs on **Linux x64** machines and builds **Android arm64** apps.

**Install it** from a clone of the repository. It needs Dart 3.8 or newer, but has only been tested with Dart 3.13.7.

```bash
dart pub global activate --source path packages/flutter_ota_cli
export PATH="$PATH:$HOME/.pub-cache/bin"      # if this folder is not on your PATH yet
flutter_ota --version
```

Once published on pub.dev, the install command will be `dart pub global activate flutter_ota_cli`.

### Settings

For each setting, the first match wins:
1. a flag;
2. an environment variable;
3. `~/.config/flutter_ota/config.yaml` (or `$XDG_CONFIG_HOME/flutter_ota/config.yaml`; mode 0600).

| Setting | Environment variable | Meaning |
| --- | --- | --- |
| `server-url` | `FLUTTER_OTA_SERVER_URL` | Your OTA server. `https://` only; `http://` only for localhost testing |
| `toolchain-index-url` | `FLUTTER_OTA_TOOLCHAIN_INDEX` | Signed toolchain index (`https://`, `file://` or `http://localhost`) |
| — | `FLUTTER_OTA_ADMIN_KEY` | Admin API key for the commands that talk to the server. **Never stored** in any file by `flutter_ota` |

Other environment variables:

| Variable | Meaning |
| --- | --- |
| `FLUTTER_OTA_CACHE` | Toolchain cache folder (default `~/.cache/flutter_ota`) |
| `FLUTTER_OTA_CONFIG_DIR` | Folder of `config.yaml` (default `~/.config/flutter_ota`) |
| `FLUTTER_OTA_KEYS_DIR` | Signing-key folder (default `<config dir>/keys`) |
| `FLUTTER_OTA_BUILD_ROOT` | Canonical build folder (default `/tmp/flutter_ota-build`) |
| `FLUTTER_OTA_TOOLCHAIN_DIR` | Use an already installed toolchain folder. Its install record is still verified |

Never put private keys or admin secrets into `flutter_ota.yaml` or the config file.

### `init`

```bash
flutter_ota init --app-id <server app UUID> [--force]
```

Writes `flutter_ota.yaml` with exactly one line, `app_id: <uuid>`.
- The value must be the **server application UUID** (a version-4 UUID). Slugs and package names are refused.
- An existing file is overwritten only with `--force`.
- Without `--app-id`, it asks for the UUID (in a terminal only).

### `config`

```bash
flutter_ota config set server-url https://ota.example.com
flutter_ota config get server-url             # the value that is actually used
flutter_ota config list                       # all settings and where each one comes from
flutter_ota config unset server-url
flutter_ota config add-toolchain-key <key_id> <public_key_base64>
flutter_ota config remove-toolchain-key <key_id>
```

`add-toolchain-key` trusts an extra **public** key for the toolchain index, for example when you build the toolchain yourself.

### `toolchain`

| Command | What it does |
| --- | --- |
| `toolchain list [--offline]` | Installed toolchains, and the ones in the verified index. `*` marks this project's pinned toolchain |
| `toolchain install [id] [--force]` | Installs the toolchain from `flutter_ota.lock` (or `id`, or the newest). Writes `flutter_ota.lock` if the project has none. `--force` reinstalls |
| `toolchain doctor [id]` | Checks the installed toolchain: file hashes, overlay, engine mirror, tool snapshots, toolchain id, disk space |
| `toolchain clean [--unused \| --all] [--yes]` | Deletes downloads and leftovers. `--unused` also deletes toolchains no known project pins, and `--all` deletes every toolchain (both ask first) |

### `upgrade`

```bash
flutter_ota upgrade [--to <toolchain id>] [--yes]
```

- Shows the current and the new toolchain, and asks `[y/N]`.
- Only after a yes does it install the new toolchain and rewrite `flutter_ota.lock`.
- Without a terminal and without `--yes`, it changes nothing.

A new toolchain needs a **new store release**.

### `keys`

```bash
flutter_ota keys init [--environment production] [--validity-days 365] [--server-url <url>]
flutter_ota keys list
```

**`keys init`** creates the keys under `~/.config/flutter_ota/keys/<app_id>/` (folders mode 0700, key files mode 0600):
- an offline **root key**, if the app has none;
- a **signer key**;
- a root-signed **certificate** for the signer key.

It registers the root **public** key and the certificate with the server. Private keys never leave your machine.

**`keys list`** works offline.

See [security](security.md#developer-owned-signing).

### `doctor`

```bash
flutter_ota doctor [--environment production] [--server-url <url>]
```

Read-only checks before a release:
- `flutter_ota.yaml`;
- the Flutter app and its Android folder;
- the SDK dependency and the `FlutterOta.initialize(` call;
- the `.gitignore` advice;
- `flutter_ota.lock` and the toolchain;
- the server URL and its health, the admin key, the app on the server;
- root keys and the signer certificate.

Each problem gets a `fix:` line.

### `release android`

```bash
flutter_ota release android [--kind aab|apk] [--build-name <x.y.z>] [--build-number <n>] \
  [--environment production] [--channel <name>] [--server-url <url>] [-- <extra flutter build args>]
```

It builds the store release on your machine and registers it. The default kind is `aab`.

1. **Server checks:** the app exists, root keys are registered, and this version is not yet registered.
2. **Toolchain:** the pinned toolchain is resolved, and installed if missing. Stock Flutter is never used.
3. **Generated files**, written in your project (commit them):
   - `lib/flutter_ota_features.g.dart`: the feature registry;
   - `lib/flutter_ota_main.g.dart`: the build entry point;
   - the `dynamic_modules` loader package under `.flutter_ota/packages/`, with its `pubspec.yaml` entry.
4. **Build:** the app is built from a neutral copy of the workspace, so no personal paths end up in the binary. This uses the custom engine, `--target-platform android-arm64` and a generated dynamic interface.
5. **Engine check:** the APK/AAB must contain the toolchain's engine.
6. **Local baseline**, in `.flutter_ota/releases/<release_id>/`, needed for patches:
   - `release.json`, `link.dill`, the interface and the host package list;
   - `libapp.so` and its hash.
7. **Registration:** the release and its `libapp.so` hash are registered with the server. The APK/AAB and the source code are **not** uploaded.

**Arguments you can't pass** after `--`, because the release sets them itself:
- `--target-platform`, `--extra-front-end-options`, `-t/--target`;
- `--debug`, `--profile`, `--obfuscate`;
- `--dart-define-from-file`, `--build-name`, `--build-number`;
- a `FLUTTER_OTA_CONFIG` define.

### `features`

```bash
flutter_ota features [--json]           # show the feature graph
flutter_ota features generate [--check] # write lib/flutter_ota_features.g.dart (--check: only verify)
```

The graph shows features, shared (host-owned) packages and the reasons for each classification. `generate --check` exits with code 1 when a generated file is out of date. See [feature patching](feature-patching.md).

### `patch android`

```bash
flutter_ota patch android [--release <id>] [--channel <name>] [--rollout <percent>] [--note <text>] [--dry-run]
```

It builds a patch against a store release (default: the newest local one), then signs and uploads it.

**Steps:**
1. Detects the changed feature packages since the release, and computes the dependency closure.
2. Checks that freezed / json_serializable output is up to date.
3. Renames the patched packages, runs the security guard (`patch_guard`), compiles to bytecode (`dart2bytecode`) and runs the reference bytecode verifier.
4. Writes the manifest and **signs it locally** with your certified signer key.
5. Uploads the patch as a `dbc-v1` draft. It is published to `--channel` only when you give one (`--rollout` defaults to 100).

**Options:**
- `--dry-run` stops before the upload.
- `--rollout` is a percentage of devices.

**Exit codes:**
- 3: a change needs a new store release (the message says why);
- 4: the security guard or the verifier rejected the code.

### `status`

```bash
flutter_ota status [--release <id>] [--json]
```

It changes nothing. It shows:
- the app;
- the store release;
- its patches on the server (number, status, format, channels with rollout %, patch id);
- the device summary for that release version.

`--json` prints one object with the keys `server_url`, `app`, `release`, `patches`, `patches_problem`, `devices` and `devices_problem`.

### `rollback`

```bash
flutter_ota rollback [--release <id>] [--patch <number>] [--reason <text>] [--yes]
```

It rolls back a **published** patch. The default is the highest-numbered published patch of the newest local release.

**Before it acts:**
- It shows what will happen and asks `[y/N]`.
- Without a terminal and without `--yes`, it changes nothing.

**What happens:**
- Devices return to the newest other published patch, or to the store code, at their next start.
- Nothing is deleted.
- `--reason` is only printed: the server API has no reason field.

To stop a patch for good, use `ota patch revoke`.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Error, a failed check, or a "no" answer |
| 3 | `patch android`: the change needs a new store release |
| 4 | `patch android`: the guard or verifier rejected the code |
| 64 | Wrong command-line usage |

## Admin CLI (`ota`)

The Python `ota` tool calls the [admin API](api-reference.md). It is built locally and is not on PyPI. It needs Python 3.10+.

```bash
./flutter-ota-system.sh cli               # builds the tool and installs it into .venv-cli/
./flutter-ota-system.sh ota app list      # runs it against the local stack

export OTA_API_URL=https://ota.example.com   # any other server
export OTA_API_KEY=<the server's OTA_ADMIN_API_KEY>
.venv-cli/bin/ota app list
```

Every command prints JSON (`patch list` prints a table). On an API error it prints `error <HTTP status>: <detail>` and exits with a non-zero code. `ota <group> <command> --help` shows all options.

| Command | Purpose |
| --- | --- |
| `ota app create <slug> "<name>" [--distribution enterprise\|public_store]` | Create an app with the channels `dev`, `staging` and `production` |
| `ota app list` | List apps, including their UUIDs (the `app_id` for `flutter_ota init`) |
| `ota app approve-policy <slug> --reason "<text>" [--revoke]` | Record or withdraw the policy approval for original-alpha AOT patches on a `public_store` app |
| `ota app policy-history <slug>` | Approval history |
| `ota release list <app>` | Releases with their artifacts |
| `ota release delete <app> --version <v> [--platform android]` | Delete a release and its patches (refused while a patch is published) |
| `ota patch list <app> --platform android --release <version>` | Patches of a release |
| `ota patch show <patch_id>` | Full patch JSON with event counts |
| `ota patch publish <patch_id> --channel C --percent P [--force --reason R]` | Publish a draft or rolled-back patch |
| `ota patch rollout <patch_id> --channel C --percent P [--force --reason R]` | Change a published patch's rollout on a channel |
| `ota patch promote <patch_id> [--from staging] [--to production] [--percent 100] [--force --reason R]` | Copy a tested patch to another channel. Refused unless it is live on `--from` with no boot failures |
| `ota patch rollback <patch_id>` | Mark a published patch `rolled_back` |
| `ota patch revoke <patch_id> [--yes]` | Revoke for good (asks you to type `revoke`) |

**Promotion rule.** The server enforces this for protected channels (`OTA_PROTECTED_CHANNELS`, default `production`):
- raising a patch's rollout there needs an earlier deployment on another channel, and no reported boot failures;
- otherwise the request fails with `409 promotion_checks_failed`;
- `--force --reason "…"` overrides it, and the server logs the reason.

**Original alpha commands.** These still work, but are not used by the bytecode architecture:
- `ota release android`, `ota release create`, `ota patch android`, `ota patch create`: the server-signed `mock-v1` / `aot-bidiff-android-v1` flow;
- `ota key show [--dart]`: the server's signing key for that flow.

See [releases and patches](releases-and-patches.md#original-alpha-patch-formats).
