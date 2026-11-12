<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLI reference (`flutter_ota`)

`flutter_ota` is the developer command-line tool of Flutter OTA System (package
[`packages/flutter_ota_cli`](../packages/flutter_ota_cli)). It is an **experimental alpha**,
for **Linux x64** machines building **Android arm64** apps.

The Python `ota` tool ([cli-reference.md](cli-reference.md)) stays the tool for server
administration (apps, channels, rollouts). The two do different jobs.

Milestone 4B added `init`, `config`, `toolchain` and `upgrade`. Milestone 4H added `status` and
`rollback` (described below).

## Install

From a clone of the repository, with Dart 3.8 or newer (for example the Dart inside a Flutter SDK;
tested only with Dart 3.13.7 from Flutter 3.47.9):

```bash
dart pub global activate --source path packages/flutter_ota_cli
export PATH="$PATH:$HOME/.pub-cache/bin"      # if dart says this folder is not on your PATH
flutter_ota --version
```

## Settings and where they come from

Settings are looked up in this order (the first one found wins):

1. a command-line flag;
2. an environment variable;
3. the user config file `~/.config/flutter_ota/config.yaml` (or
   `$XDG_CONFIG_HOME/flutter_ota/config.yaml`; mode 0600).

| Setting | Environment variable | Meaning |
| --- | --- | --- |
| `server-url` | `FLUTTER_OTA_SERVER_URL` | Your OTA server. `https://` only; `http://` only for `localhost` testing |
| `toolchain-index-url` | `FLUTTER_OTA_TOOLCHAIN_INDEX` | Signed toolchain index (`https://`, `file://` or `http://localhost`) |

Other environment variables:

| Variable | Meaning |
| --- | --- |
| `FLUTTER_OTA_CACHE` | Cache folder (default `~/.cache/flutter_ota`) |
| `FLUTTER_OTA_CONFIG_DIR` | Folder of `config.yaml` (default `~/.config/flutter_ota`) |

**Never** put private keys or admin secrets into `flutter_ota.yaml` or the config file.

## `flutter_ota init`

```bash
flutter_ota init --app-id 3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f
```

Run it in the root folder of your Flutter app. It writes `flutter_ota.yaml` with exactly one line:

```yaml
app_id: 3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f
```

- `app_id` is the **server application UUID** (the `id` shown by `ota app list`). The slug, the
  Android package name and anything that is not a version-4 UUID are refused.
- An existing file is not overwritten unless you add `--force`.
- Without `--app-id`, it asks for the UUID (in a terminal only).

## `flutter_ota config`

```bash
flutter_ota config set server-url https://ota.example.com
flutter_ota config get server-url            # prints the value that is actually used
flutter_ota config list                      # all settings and where each comes from
flutter_ota config unset server-url
flutter_ota config add-toolchain-key <key_id> <public_key_base64>
flutter_ota config remove-toolchain-key <key_id>
```

`add-toolchain-key` trusts an extra **public** key for the toolchain index, for example your own
key when you build the toolchain yourself ([toolchain-management.md](toolchain-management.md#6-building-the-toolchain-yourself)).

## `flutter_ota toolchain`

| Command | What it does |
| --- | --- |
| `toolchain list [--offline]` | Installed toolchains, and the ones in the verified index. `*` marks the toolchain pinned by this project |
| `toolchain install [id] [--force]` | Installs the toolchain from `flutter_ota.lock`, or `[id]`, or the newest one. In a project without a lock, writes `flutter_ota.lock`. `--force` reinstalls |
| `toolchain doctor [id]` | Checks the installed toolchain: file hashes, overlay applied, Maven mirror, tool snapshots, toolchain id, engine pin, disk space. Exit code 1 if a check fails |
| `toolchain clean` | Deletes downloaded archives and leftovers of interrupted installs |
| `toolchain clean --unused [--yes]` | Also deletes toolchains that no known project pins (asks first) |
| `toolchain clean --all [--yes]` | Deletes every installed toolchain (asks first) |

In a project that is pinned to one toolchain, `toolchain install <other id>` is refused; use
`upgrade --to <other id>`.

## `flutter_ota upgrade`

```bash
flutter_ota upgrade              # newest compatible toolchain; asks [y/N]
flutter_ota upgrade --to <id>    # a specific toolchain
flutter_ota upgrade --yes        # CI: no question
```

It shows the current and the new toolchain and asks for confirmation. Only after a yes does it
install the new toolchain and rewrite `flutter_ota.lock`. Without a terminal and without `--yes`,
it stops and changes nothing.

## `flutter_ota status`

```bash
flutter_ota status                      # newest local release
flutter_ota status --release <uuid>     # a specific local release
flutter_ota status --json               # machine-readable output (for scripts and CI)
```

It reads `app_id` from `flutter_ota.yaml` and the newest local release from
`.flutter_ota/releases/`, then asks the server (it needs `FLUTTER_OTA_ADMIN_KEY`) and shows:

- the app (slug and UUID);
- the release (id, version, environment, and whether it is registered on the server);
- the release's patches: number, status, format, channels with rollout percent, and patch id;
- the device summary for that release version (how many devices run which patch, from their last
  update check).

It changes nothing. If the server has no patches for the release yet, it says so. Example:

```text
Server:   https://ota.example.com
App:      shop  (id 7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5)
Release:  98657508-43bd-4e97-a7f1-f9057b50cd23
          version 1.0.0, environment production, registered on the server

Patches (2):
  NO  STATUS       FORMAT   CHANNELS (ROLLOUT)       PATCH ID
  1   rolled_back  dbc-v1   stable 100%              <patch uuid>
  2   published    dbc-v1   stable 100%, beta 12.5%  <patch uuid>
  published = devices can download it; draft = uploaded, not published yet;
  rolled_back = devices stopped using it; revoked = it must never run again.

Devices (from their last update check, version 1.0.0):
  android, channel stable: patch 2 - 3 devices
  android, channel stable: store code (no patch) - 1 device
```

With `--json`, the output is one JSON object with the keys `server_url`, `app`, `release`,
`patches` (each with `number`, `id`, `format`, `status`, `channels`, `note`, `created_at`),
`patches_problem`, `devices` (every row of the server's device summary for the app, all versions)
and `devices_problem`. `patches` is `null` when the patches could not be listed (for example, the
release is not registered); `patches_problem` then says why.

## `flutter_ota rollback`

```bash
flutter_ota rollback                         # highest-numbered published patch of the newest release; asks [y/N]
flutter_ota rollback --patch 2               # a specific patch number
flutter_ota rollback --release <uuid>        # a specific local release
flutter_ota rollback --reason "crash on start" --yes   # CI: no question
```

It rolls a **published** patch back with the server's `POST /v1/admin/patches/{id}/rollback`.
Before it asks, it shows the patch, its channels and what will happen:

- the server marks the patch `rolled_back`; nothing is deleted;
- devices that run it go back to the newest other published patch for their channel, or to the
  store code (no patch), at their next start;
- the patch can be published again later (`ota patch publish <patch_id> --channel <channel>`).

Without a terminal and without `--yes`, it stops and changes nothing. It refuses a patch that is
not published (already rolled back, a draft, or revoked) and changes nothing. `--reason` is only
printed with the summary: the server's rollback API has no reason field, so the reason is not
stored. To stop a patch for good, use `ota patch revoke` (the Python tool); `flutter_ota` has no
revoke command.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Error (the message starts with `error:`), a failed doctor check, or a "no" answer |
| 64 | Wrong command-line usage |

## For later milestones (Dart API)

```dart
import 'package:flutter_ota_cli/flutter_ota_cli.dart';

final lock = Lockfile.readIn(projectDir)!;
final tc = await ToolchainManager(CliContext()).resolve(lock);  // verifies every recorded file
tc.flutterBin;          // the toolchain's own flutter
tc.buildEnvironment;    // FLUTTER_STORAGE_BASE_URL=file://<mirror>, GRADLE_USER_HOME=<isolated>
tc.toolSnapshotPaths;   // dart2bytecode, pkg_rename, patch_guard (run with tc.dartAotRuntime)
```

`resolve` throws `ToolchainUnavailableException` when the toolchain is missing or changed. There is
no fallback to a stock or global Flutter SDK.
