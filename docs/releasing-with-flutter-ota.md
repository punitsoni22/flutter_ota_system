<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Releasing an app with `flutter_ota`

Status: **experimental alpha, Phase 4 milestone 4D.** Linux x64 developer machines, Android arm64
apps only. Tested with unit tests (fake toolchain, fake backend) and local smoke builds of a tiny
app (with the real SDK package). Not tested on iOS, macOS or Windows, and not on a phone in this milestone.

This page explains how to make a **store release** that can receive bytecode patches later:

1. check your setup with `flutter_ota doctor`;
2. create the app's signing keys once with `flutter_ota keys init`;
3. build and register the release with `flutter_ota release android`.

Commands of milestone 4B (`init`, `config`, `toolchain`, `upgrade`) are in
[cli-reference-flutter-ota.md](cli-reference-flutter-ota.md). The toolchain itself is explained in
[toolchain-management.md](toolchain-management.md).

## 1. Before the first release

You need:

- a Flutter app with an `android/` folder;
- `flutter_ota_system` in the app's `dependencies`, and this in `lib/main.dart`:

  ```dart
  Future<void> main() async {
    WidgetsFlutterBinding.ensureInitialized();
    await FlutterOta.initialize();
    runApp(const MyApp());
  }
  ```

- nothing else in `main.dart`: the CLI generates the store build's entry point (section 3.4);
- `flutter_ota.yaml` with only `app_id` (`flutter_ota init --app-id <server application UUID>`);
- `flutter_ota.lock` (`flutter_ota toolchain install` writes it; commit it);
- the server URL, once per machine:

  ```bash
  flutter_ota config set server-url https://ota.example.com
  ```

- the server's **admin API key**, in an environment variable (see section 5):

  ```bash
  read -rs FLUTTER_OTA_ADMIN_KEY && export FLUTTER_OTA_ADMIN_KEY
  ```

Then run:

```bash
flutter_ota doctor
```

`doctor` only reads; it builds nothing and changes nothing. Each line is `[ok]`, `[!]` (warning) or
`[x]` (must be fixed), with a `fix:` line that says what to do. It checks:

| Check | What it means |
| --- | --- |
| `flutter_ota.yaml` | exists, contains only `app_id`, and `app_id` is a UUID |
| flutter app, android project | `pubspec.yaml` depends on the Flutter SDK; `android/app/build.gradle(.kts)` exists |
| SDK dependency | `pubspec.yaml` depends on `flutter_ota_system` |
| `FlutterOta.initialize` | `lib/main.dart` calls it (a simple text check, so only a warning) |
| `.gitignore` | `.flutter_ota/releases/` is ignored, but not all of `.flutter_ota/` (warning only; see section 4) |
| `flutter_ota.lock`, toolchain | the pinned toolchain is installed and every recorded file matches |
| server URL, server reachable | the URL is set and `GET /health/live` answers |
| admin key | `FLUTTER_OTA_ADMIN_KEY` is set and the server accepts it |
| app on server | the server has an application with this `app_id` |
| root keys, signer key | your root key is registered; you have a valid signer certificate |

## 2. Signing keys (`flutter_ota keys init`)

Patches are signed **on your machine**. The server never signs them and never sees a private key.

```bash
flutter_ota keys init                      # environment "production", certificate valid 365 days
flutter_ota keys init --environment staging --validity-days 90
flutter_ota keys list                      # what is on this machine (works offline)
```

`keys init` is safe to run again. It:

1. creates a **root key** for the app, if this machine has none;
2. creates a **signer key** and a certificate for it, signed by the root key, if there is no valid
   one for that environment;
3. registers the root **public** key and the certificate with the server.

The keys live outside every project:

```text
~/.config/flutter_ota/keys/<app_id>/
  roots/<key_id>.key          ROOT private key (mode 0600)
  roots/<key_id>.pub          root public key (compiled into your app)
  signers/<key_id>.key        signer private key (mode 0600)
  signers/<key_id>.pub
  signers/<key_id>.cert.json  certificate (public)
```

- **Back up the root `.key` file offline** (for example on an encrypted USB stick). It is only
  needed to certify a new signer key or to revoke keys. If you lose it, apps already in the store
  can never trust a new signer.
- Never copy a `.key` file into a project, a repository, a ticket or a chat.
- A teammate or a CI job that only **builds releases** needs the root **`.pub`** file, not the
  `.key` file. A machine that **signs patches** needs a signer key and its certificate.

The root keys compiled into a release are the ones that are **both** on your machine (`roots/*.pub`)
**and** registered (not revoked) on the server. A key that only the server lists is never compiled
in, so a compromised server cannot add its own root key to your app.

## 3. Building a release (`flutter_ota release android`)

```bash
flutter_ota release android                    # Google Play bundle (.aab)
flutter_ota release android --kind apk         # APK
flutter_ota release android --build-name 1.4.0 --build-number 42
flutter_ota release android -- --flavor prod --dart-define=API=https://api.example.com
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--kind aab\|apk` | `aab` | what `flutter build` makes |
| `--build-name`, `--build-number` | from `version:` in `pubspec.yaml` | passed to `flutter build`; the server version is `<name>+<number>` |
| `--environment` | `production` | trust environment compiled into the app; signer certificates must match it |
| `--channel` | not set (the SDK uses `production`) | update channel compiled into the app |
| `--server-url` | from `flutter_ota config` | another server for this run |
| `-- <args>` | none | extra `flutter build` arguments |

Not allowed after `--` (the CLI sets them itself, or they are not supported yet):
`--target-platform`, `--extra-front-end-options`, `--debug`, `--profile`, `--obfuscate`,
`--dart-define-from-file`, `-t`/`--target`, `--build-name`, `--build-number`, and
`--dart-define=FLUTTER_OTA_CONFIG=...`. `--dart-define` values must not contain commas.

What the command does, in order:

1. **Checks** the project (as `doctor` does), then the server: it is reachable, the app exists,
   your root key is registered, and the version is not registered yet. Nothing is built if a check
   fails.
2. **Resolves the toolchain** pinned in `flutter_ota.lock`. If it is not installed, it installs it
   from the signed index. It never uses your global Flutter, and never a stock SDK.
3. **Chooses the release id** (a random UUID). It is compiled into the app, so it is chosen before
   the build.
4. **Adds the module loader** (section 3.4): copies the toolchain's `dynamic_modules` package to
   `.flutter_ota/packages/dynamic_modules/` and, if needed, adds it to `pubspec.yaml`.
5. Runs `flutter pub get` with the toolchain, then writes the feature registry
   (`lib/flutter_ota_features.g.dart`, see the feature-patching guide) and the entry point
   `lib/flutter_ota_main.g.dart`. These files are written in **your** project (commit them).
6. **Copies the app workspace** (the app and its path packages, including the files from step 5)
   to the neutral build folder `/tmp/flutter_ota-build/project` and runs `flutter pub get` there
   (section 3.3). Every later compile and the store build run in that copy.
7. **Computes the dynamic interface** (section 3.1) from a first kernel compile of the app.
8. **Builds the configuration** and compiles **`link.dill`** from
   `package:<app>/flutter_ota_main.g.dart`, the kernel that patches are compiled against.
9. Runs the store build in the build copy:

   ```text
   <toolchain>/flutter/bin/flutter build apk|appbundle --release -t lib/flutter_ota_main.g.dart \
     --target-platform android-arm64 \
     --dart-define=FLUTTER_OTA_CONFIG=<base64url> \
     --extra-front-end-options=--dynamic-interface=/tmp/flutter_ota-build/workspace/<app>/.flutter_ota/releases/<release_id>/dynamic_interface.yaml \
     --build-name=<name> --build-number=<number> [your extra arguments]
   ```

   with `FLUTTER_STORAGE_BASE_URL=file://<toolchain>/mirror` (the engine can only come from the
   toolchain), `GRADLE_USER_HOME=<toolchain>/gradle-home` (no cached stock engine), and the
   toolchain's `flutter/bin` first on the child process's `PATH`. Only the APK or bundle is
   copied back, to its usual place in your project (`build/app/outputs/flutter-apk/` or
   `build/app/outputs/bundle/release/`); the copy is deleted when the command ends.
10. **Verifies** that the APK or bundle contains the toolchain's own `libflutter.so` (SHA-256 of the
   copy in the toolchain's engine jar). If not, it stops and registers nothing.
11. Takes `lib/arm64-v8a/libapp.so` (in a bundle: `base/lib/arm64-v8a/libapp.so`) and hashes it.
12. Writes the **local baseline** (section 4) in your project, including the feature snapshot
    that `patch android` compares against (it hashes your real project files).
13. **Registers** the release: `POST /v1/admin/apps/{slug}/releases` with the chosen `id` and the
    baseline identity (`toolchain_id`, `dart_revision`, `bytecode_format`, `interface_sha256`,
    `trust_environment`), then uploads `libapp.so` for `arm64-v8a`. **The APK, the bundle and your
    source code are never uploaded.**

At the end it prints where the store file is (upload it to Google Play yourself) and where the
baseline folder is.

If anything fails after the build, the baseline folder is removed and the command says **not** to
upload the built file, because its release id is not registered. If the server created the
release but the upload failed, delete that release with `ota release delete` before you retry.

### 3.1 The dynamic interface

A patch can only use libraries that the store build already contains, and only in the ways the
store build allows. The **dynamic interface** (`dynamic_interface.yaml`) lists them. The CLI makes
it automatically (policy 2):

- every `package:` library in the app's kernel: Flutter, your app, your path packages and
  third-party packages;
- these `dart:` libraries: `async`, `collection`, `convert`, `core`, `developer`, `io`, `isolate`,
  `math`, `typed_data`, `ui` (never `dart:_internal`, `dart:ffi` or `dart:mirrors`);
- never `package:dynamic_modules` (a patch must not load modules) and never the generated entry
  point `flutter_ota_main.g.dart`;
- the same list in all four sections (`callable`, `can-be-used-as-type`, `extendable`,
  `can-be-overridden`).

The file is sorted and has a fixed header, so the same app gives the same file, byte for byte. Its
SHA-256 is compiled into the app and stored on the server.

Known cost: listing everything as extendable keeps more code in `libapp.so` and limits some AOT
optimisations. The size effect on a real app is **not measured yet**.

### 3.2 The configuration compiled into the app

The CLI passes **one** define, `FLUTTER_OTA_CONFIG`: base64url (with `=` padding) of canonical JSON
(sorted keys, no spaces), as described in
[the runtime contract](architecture/phase-4-runtime-contract.md):

```json
{"app_id":"…","entry_contract":3,"environment":"production","format":1,
 "host_packages":["…"],"interface_sha256":"…","release_id":"…",
 "root_keys":{"root-…":"<base64 public key>"},
 "runtime":{"abi":"android-arm64","dart":"3.13.7","engine":"89c39edf","flutter":"3.47.9",
            "runtime_id":"dbc-flutter-3.47.9-ota.1"},
 "server_url":"https://ota.example.com","toolchain_id":"…",
 "release_version":"1.4.0+42"}
```

Optional fields: `release_version` (always set by the CLI to `<build-name>+<build-number>`, the
version the backend release has, so the update check matches) and `channel` (only with
`--channel`).

It contains **no** private key, admin key or other secret.

### 3.3 Paths in the build

Compiled files record file paths. So that neither `link.dill` nor the store `libapp.so` contains
your home folder, the CLI builds below a fixed folder, `/tmp/flutter_ota-build` (mode 0700, owned
by you):

```text
/tmp/flutter_ota-build/toolchain  -> the toolchain folder
/tmp/flutter_ota-build/pub-cache  -> your pub cache
/tmp/flutter_ota-build/project/      a temporary copy of the app workspace (a real folder)
/tmp/flutter_ota-build/workspace  -> during a release: the copy; during a patch: your workspace
```

The **workspace** is the folder that holds the app and all its path packages. The Flutter tool
writes `.dart_tool/flutter_build/dart_plugin_registrant.dart` (apps with plugins) into the app
folder and compiles it by its real, symlink-free path, so a symlink is not enough for the store
build. That is why `release android` builds in a **copy** of the workspace at the real path
`/tmp/flutter_ota-build/project/` (the app keeps its place relative to its path packages, so
relative `path:` dependencies still work; absolute `path:` dependencies into the workspace are
rewritten to relative ones in the copy only).

The copy leaves out what is rebuilt or private: `build/`, `ios/`, `.flutter-plugins`,
`.flutter-plugins-dependencies`, `android/local.properties` and `.flutter_ota/releases/` of every
package, and `.dart_tool/`, `.git`, `.gradle` and `.cxx` folders anywhere. The release then runs
`flutter pub get`, the two `link.dill` compiles and `flutter build` in the copy, copies the APK or
bundle back to your project, and deletes the copy (also when the build fails). The Gradle cache
stays in the toolchain's Gradle home, but every release builds the Android part from scratch, so it
takes a little longer than a normal incremental build.

`link.dill` is compiled through `/tmp/flutter_ota-build/workspace`, which points to the copy during
a release. `patch android` points the same link at your real workspace, which has the same layout,
so the release kernel and the patch module record exactly the same `/tmp/flutter_ota-build/...`
paths.

One build at a time uses the folder (a second build waits). If that folder belongs to another user,
the CLI refuses to build; remove it, or set `FLUTTER_OTA_BUILD_ROOT` to a folder you own (then use
the same value for the release and its patches). The path packages of the app must live next to the
app (in one common folder below your home folder), and the build folder needs free space for a
copy of that workspace (without build outputs).

### 3.4 The module loader and the entry point

The pinned Dart only lets a package named `dynamic_modules` call the VM's module loader, and the
SDK cannot depend on a package from the toolchain. So the CLI (see
[the SDK runtime notes](architecture/phase-4-sdk-runtime.md), section 3):

- copies the unchanged `dynamic_modules` package from the toolchain to
  `.flutter_ota/packages/dynamic_modules/` (only its two known files);
- adds this to `pubspec.yaml` once (it tells you; commit the change):

  ```yaml
  dependencies:
    dynamic_modules:
      path: .flutter_ota/packages/dynamic_modules
  ```

  If `pubspec.yaml` already declares `dynamic_modules` in another way, the release stops;
- writes `lib/flutter_ota_main.g.dart`, which registers the loader and then calls your own
  `main()` (with `args` if your `main` takes them). Your `lib/main.dart` is never changed;
- builds with `-t lib/flutter_ota_main.g.dart`. A normal `flutter run` still uses `lib/main.dart`;
  OTA is then disabled, which is expected.

## 4. The `.flutter_ota/` folder

```text
.flutter_ota/
  packages/dynamic_modules/         module-loader package (commit it: pubspec.yaml points here)
  release.json                      copy of the latest release's release.json
  releases/<release_id>/
    release.json                    baseline identity (see below); no secrets
    link.dill                       kernel of the store build (tens of MB)
    dynamic_interface.yaml          the interface (section 3.1)
    host_packages.json              {"internal": [path packages], "all": [every package]}
    link_package_config.json        package config with the canonical paths (section 3.3)
    libapp.so                       the store build's arm64 code (the same file the server has)
    pubspec.lock                    copy of the app's lock file at release time
    feature_snapshot.json           source hashes of the feature packages (for patch android)
```

`release.json` holds: `app_id`, `release_id`, `version`, `build_name`, `build_number`,
`environment`, `server_url`, `abi`, `arch`, `libapp_sha256`, `libflutter_sha256`, the store file
(`kind`, `path`, `sha256`, `size`), `engine`, `flutter`, `dart`, `dart_revision`,
`bytecode_format`, `toolchain`, `toolchain_id`, `toolchain_record`, `runtime`,
`interface_sha256`, `interface_policy`, `interface_libraries`, `host_packages`, `root_keys`
(public), `entry_contract`, `flutter_ota_config` (the define value), `link_dill_sha256`,
`canonical_build_root`, `build_dir` (where `flutter build` ran: the build copy), `link_entry`, `link_defines`, `build_args`, `cli_version`, `created_at`
and `registered`.

**Keep every release folder.** `flutter_ota patch android` builds patches against that folder's
`link.dill`. If you lose it, you cannot patch that release.

Recommended:

- add `/.flutter_ota/releases/` to `.gitignore` (`link.dill` and `libapp.so` are large
  binaries). Do **not** ignore all of `.flutter_ota/`: `.flutter_ota/packages/dynamic_modules/`
  must be committed, or `flutter pub get` fails in a fresh clone;
- back up each `releases/<release_id>/` folder, for example as a CI build artifact next to the
  store file;
- `release.json` has no secrets, so you may also commit it if you want a record in git.

## 5. The admin key

The admin API key is read **only** from the environment variable `FLUTTER_OTA_ADMIN_KEY`.
`flutter_ota` never writes it to a file: not to the project, and not to
`~/.config/flutter_ota/config.yaml` (there is deliberately no `config set admin-key`). In CI, store
it as a secret variable. On your machine, type it with `read -rs` so it stays out of your shell
history.

## 6. Developer and owner escape hatch: `FLUTTER_OTA_TOOLCHAIN_DIR`

`FLUTTER_OTA_TOOLCHAIN_DIR=<dir>` makes the CLI use an already-installed toolchain folder instead
of the cache entry. It is meant for people who build toolchains. The folder must still contain an
`install.json` for the toolchain pinned in `flutter_ota.lock`, and every recorded file is verified,
exactly as for a normal install. It is not a way to use a stock SDK.

`FLUTTER_OTA_DYNAMIC_MODULES_DIR=<dir>` does the same for the `dynamic_modules` package, for
toolchains built before milestone 4D that do not ship it yet.

## 7. After a patch: `flutter_ota status` and `flutter_ota rollback`

`flutter_ota status` shows the newest release, its patches on the server (status, channels,
rollout) and how many devices run which patch. It changes nothing.

If a patch causes problems, roll it back:

```bash
flutter_ota rollback              # the highest-numbered published patch; asks [y/N]
flutter_ota rollback --patch 2    # a specific patch
```

Devices that run the patch go back to the newest other published patch, or to the store code, at
their next start. Nothing is deleted. See [cli-reference-flutter-ota.md](cli-reference-flutter-ota.md)
for all options.

## 8. Known limits

- Linux x64 hosts and Android arm64 only. Other ABIs in the APK are not patched.
- `lib/main.dart` is the only app entry point; `--target` is not supported yet.
- Fixed: the store `libapp.so` of an app with plugins used to contain the absolute path of
  `.dart_tool/flutter_build/dart_plugin_registrant.dart` in your project folder (often with your
  user name). The store build now runs in the neutral build copy (section 3.3), so that path is
  `/tmp/flutter_ota-build/project/<app>/.dart_tool/...`. It still contains the folder names
  of your workspace below that root (for example `<app>`), as `link.dill` always did.
- Obfuscated builds (`--obfuscate`) and `--dart-define-from-file` are refused for now.
- The release routes of the backend address the app by slug, so the CLI looks the slug up from the
  app UUID.
- Store size and start-up cost of the full interface are not measured yet.
