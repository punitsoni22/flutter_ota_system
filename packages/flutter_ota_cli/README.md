# flutter_ota_cli

`flutter_ota`, the developer command-line tool of **[Flutter OTA System](https://github.com/punitsoni22/flutter_ota_system)**,
an open-source, **self-hosted** over-the-air (OTA) update platform for Flutter apps. Your servers,
your signing keys, your control.

> [!WARNING]
> **Experimental alpha. Not production-ready.**
> - Runs on **Linux x64** developer machines only, and builds **Android arm64** apps only.
> - Tested end to end with one Android 13 arm64 phone.
> - No independent security audit, and no app-store approval of any kind.

## What it does

Everything happens on **your** machine:

- **Toolchain:** downloads, verifies and caches the Flutter OTA toolchain (Flutter 3.47.9 /
  Dart 3.13.7 or Flutter 3.50.0 / Dart 3.14.0, with our custom engine) automatically, choosing the newest one
  your project can build with. Your global Flutter is never used or changed.
- **Keys:** creates your signing keys (`keys init`): an offline root key and a certified signer key.
- **Store release:** builds the store AAB/APK with the custom engine and registers the release with
  your server (`release android`). You upload the AAB to the store yourself.
- **Patches:** finds what changed in your feature packages, compiles it to Dart bytecode, verifies
  it, signs it locally and uploads it (`patch android`).
- **Operations:** shows patches and devices, and rolls back (`status`, `rollback`).

Your source code is never uploaded, and the server never holds your private signing keys.

The app side is the [`flutter_ota_system`](https://pub.dev/packages/flutter_ota_system) package.
You also need your own Flutter OTA System server
([self-hosting](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/self-hosting.md)).

## Requirements

| | |
| --- | --- |
| Developer machine | Linux x64, about 10 GB of free disk, internet access for the first install |
| Dart | 3.8 or newer to run the CLI (for example the `dart` of your Flutter install); tested with 3.13.7 |
| App | A Flutter Android app, arm64-v8a only |
| Toolchain | Flutter 3.47.9 or 3.50.0 with the Flutter OTA engine, chosen per project: **downloaded by the CLI** (about 1.6 GB, plus about 2 GB of Android build tools at the first release build) |

## Install

```bash
dart pub global activate flutter_ota_cli
export PATH="$PATH:$HOME/.pub-cache/bin"      # add this line to ~/.bashrc to keep it
flutter_ota --help
```

## Commands

| Command | What it does |
| --- | --- |
| `flutter_ota init --app-id <uuid>` | Writes `flutter_ota.yaml` with your server's app id (asks if you leave it out) |
| `flutter_ota config set\|get\|unset\|list` | Settings `server-url` and `toolchain-index-url` |
| `flutter_ota config add-toolchain-key\|remove-toolchain-key` | Trust a private toolchain mirror's public key |
| `flutter_ota doctor` | Checks the project, toolchain, server and keys (read-only) |
| `flutter_ota toolchain install\|list\|doctor\|clean` | Installs (writes `flutter_ota.lock`), lists, checks and cleans toolchains |
| `flutter_ota upgrade` | Moves the project to a newer toolchain (asks first) |
| `flutter_ota keys init\|list` | Creates and lists your signing keys |
| `flutter_ota release android` | Builds and registers a store release (`--kind aab\|apk`, `--build-name`, `--build-number`) |
| `flutter_ota features [generate]` | Shows the feature packages; writes the feature registry |
| `flutter_ota patch android` | Builds, signs and uploads a patch (`--release`, `--channel`, `--rollout`, `--note`, `--dry-run`) |
| `flutter_ota status` | Release, patches, channels, rollout and devices |
| `flutter_ota rollback` | Rolls back a published patch (`--release`, `--patch`, `--reason`, `--yes`) |

The admin API key is read from the `FLUTTER_OTA_ADMIN_KEY` environment variable and never stored in
a file. `flutter_ota <command> --help` shows every option.

## A short session

In your Flutter app folder:

```bash
flutter_ota init --app-id <server app UUID>          # writes flutter_ota.yaml
flutter_ota config set server-url https://ota.example.com
export FLUTTER_OTA_ADMIN_KEY=<admin API key>

flutter_ota toolchain install                        # downloads and verifies the toolchain; writes flutter_ota.lock
flutter_ota keys init                                # offline root key + signer key, on this machine only
flutter_ota doctor

flutter_ota release android                          # store AAB, built locally
# ...change code in a feature package...
flutter_ota patch android --channel staging          # build, check, sign and upload a patch
flutter_ota status
flutter_ota rollback                                 # if something goes wrong
```

The server only lets a patch reach `production` after it ran on another channel such as
`staging`; promotion is done with the server's admin tool (see the quick start).

## Documentation

- [Quick start](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/quick-start.md)
- [CLI reference](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/cli-reference.md)
- [Toolchain management](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/toolchain-management.md)
- [Feature patching](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/feature-patching.md)
- [Troubleshooting](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/troubleshooting.md)
- [Compatibility and limitations](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/limitations.md)
- [Security](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/security.md)

## Development

From `packages/flutter_ota_cli` in the repository:

```bash
dart pub get && dart analyze && dart test
```

## Links and licence

- Repository: <https://github.com/punitsoni22/flutter_ota_system>
- Issues: <https://github.com/punitsoni22/flutter_ota_system/issues>
- Security reports: see [SECURITY.md](https://github.com/punitsoni22/flutter_ota_system/blob/main/SECURITY.md)

Apache License 2.0, Copyright The Punit Authors.
