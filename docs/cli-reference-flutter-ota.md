<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLI reference (`flutter_ota`)

`flutter_ota` is the developer command-line tool of Flutter OTA System (package
[`packages/flutter_ota_cli`](../packages/flutter_ota_cli)). It is an **experimental alpha**,
for **Linux x64** machines building **Android arm64** apps.

The Python `ota` tool ([cli-reference.md](cli-reference.md)) stays the tool for server
administration (apps, channels, rollouts). The two do different jobs.

Milestone 4B has these commands: `init`, `config`, `toolchain`, `upgrade`. Release and patch
commands come in later milestones.

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
