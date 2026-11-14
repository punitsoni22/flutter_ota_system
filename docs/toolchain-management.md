<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Toolchain management

Status: **experimental alpha** (`v0.3.0-alpha`). Linux x64 developer machines only, Android
arm64 apps, two toolchains: `flutter-3.47.9-ota.1` (Flutter 3.47.9 / Dart 3.13.7) and
`flutter-3.50.0-ota.1` (Flutter 3.50.0 / Dart 3.14.0), with our custom engine. The toolchain is published as assets of the GitHub release, and `flutter_ota` downloads
and verifies it for you.

This page explains:

1. what the OTA toolchain is;
2. how `flutter_ota` installs, checks, upgrades and cleans it, and how to use a private mirror;
3. the index, lock file and cache formats;
4. how an install is protected;
5. how the owner builds and signs the release files;
6. how a developer can build the toolchain themselves;
7. Flutter upgrades;
8. known limits.

Commands are listed in the [CLI reference](cli-reference.md#toolchain).

## 1. What the toolchain is

Bytecode patches need a Flutter engine with the Dart bytecode interpreter (and our bytecode
verifier) compiled in. A stock Flutter SDK cannot load patches. A toolchain is:

- a **stock Flutter SDK** (for example 3.47.9), downloaded from the official release archive;
- plus our **overlay**, an archive (about 54 MB for 3.47.9) that contains:
  - our `gen_snapshot` (android-arm64-release, linux-x64 host), which replaces the stock one;
  - a local **Maven mirror** with our `libflutter.so` (inside the `arm64_v8a_release` jar), its POM,
    and the unmodified official embedding jar and POM. Like the official jar, it holds the engine
    with its debug symbols: the Android Gradle plugin strips them when it builds the APK or AAB
    (an app bundle build needs them), so the app does not grow;
  - four tool snapshots: `dart2bytecode`, `pkg_rename`, `patch_guard` and `bc_verify` (the
    reference bytecode verifier that `flutter_ota patch android` runs on every module);
  - the unchanged `dynamic_modules` package (`packages/dynamic_modules/`, from
    `prototypes/real_app_compatibility/packages/dynamic_modules`). Only a package with this name
    may call the Dart VM's module loader, so `flutter_ota release android` copies it into the app
    (see the [CLI reference](cli-reference.md#release-android));
  - `toolchain.json`, the content-hash record of the toolchain (its `id` is the `toolchain_id`);
  - licence notices (Flutter and Dart are BSD-3-Clause; our tools are Apache-2.0).

The toolchain lives in the CLI's own cache. **Your global Flutter, your PATH, your Gradle cache and
your Android SDK are never used or changed.** Builds run the toolchain's own
`flutter` with:

```text
FLUTTER_STORAGE_BASE_URL=file://<toolchain>/mirror   # the engine can only come from our mirror
GRADLE_USER_HOME=<toolchain>/gradle-home             # no cached stock engine can be picked up
```

If the pinned toolchain is missing or fails verification, the CLI stops with a clear error. It
**never** falls back to a stock or global Flutter SDK.

## 2. Using it (developer)

In your Flutter app folder (after `flutter_ota init`):

```bash
flutter_ota toolchain install      # downloads, verifies, installs, writes flutter_ota.lock
flutter_ota toolchain doctor       # checks the installed toolchain
```

Commit `flutter_ota.lock` with your app, so every developer and CI job uses the same toolchain.
You need no other setting: each CLI version has the URL of its own toolchain index built in.

### 2.1 Where it comes from

For `v0.3.0-alpha`, the index is
`https://github.com/punitsoni22/flutter_ota_system/releases/download/v0.3.0-alpha/toolchain-index.json`
(serial 2, signed by `flutter-ota-toolchain-1`). The
[GitHub release](https://github.com/punitsoni22/flutter_ota_system/releases/tag/v0.3.0-alpha) has
these files:

| File | What it is |
| --- | --- |
| `toolchain-index.json` | The signed index (ES256). **The only file the CLI trusts**; every other download is checked against it |
| `flutter-3.47.9-ota.1-linux-x64.tar.gz` | Overlay for Flutter 3.47.9: 53,806,362 bytes, SHA-256 `8887b78bb89e26ff8e4d752389f697fd322499a2c6feaf0eb929e9d81df8dd5d`, engine build ID `cbce549523681a8db4ebd7a27a2876625867f64a` (identical to v0.2.0-alpha) |
| `flutter-3.50.0-ota.1-linux-x64.tar.gz` | Overlay for Flutter 3.50.0: 55,122,803 bytes, SHA-256 `7eae80a19277b75256e319f3aab5f5371a59fc1a67a6a4f5d66c3e33d4a154bc`, engine build ID `c9ecf2e22a18d86fc619668200137cfed5ab48b7` |
| `toolchain-manifest.json` | For people (format 2): per toolchain the versions, engine commit, engine build ID, sizes and SHA-256 |
| `SHA256SUMS` | SHA-256 of the release files, for a manual check with `sha256sum -c` |

The stock **Flutter SDK** archives are not release files: the CLI downloads them from Google's
official Flutter release URLs listed in the signed index (3.47.9: 1,582,752,184 bytes; 3.50.0:
1,517,633,656 bytes) and checks each against the size and SHA-256 recorded there. CLI 0.2.0-alpha.x
still uses the v0.2.0-alpha index (Flutter 3.47.9 only).

**Several Flutter versions.** One index lists several toolchains. The release carries one overlay
per toolchain; `toolchain-manifest.json` (format 2) lists every toolchain with its engine
build ID, and `SHA256SUMS` covers every overlay. Each toolchain is installed in its own folder of the
cache, with its own Gradle home, so they never affect each other.

**Which toolchain a project gets.** `flutter_ota toolchain install` in a project without
`flutter_ota.lock` picks the **newest toolchain the project can build with**:
- its Dart version must match `environment: sdk:` in `pubspec.yaml`;
- the project's Android build tools must meet the minimums that toolchain's Flutter enforces
  (Flutter 3.50: Gradle 9.3.1, Android Gradle plugin 9.1.1, Kotlin Gradle plugin 2.4.10, in
  `android/gradle/wrapper/gradle-wrapper.properties` and `android/settings.gradle(.kts)`).

It prints why it skipped a newer toolchain, for example
`Skipping flutter-3.50.0-ota.1: needs newer Android build tools (Gradle 9.1.0 < 9.3.1, ...)`.
`flutter_ota toolchain install <id>` installs a specific one.

### 2.2 What `toolchain install` checks

1. It downloads the index and checks its ES256 signature with the key built into the CLI
   (`flutter-ota-toolchain-1`, public key `BIf+3nTyIc2zDfYQtoQMMFHiBNRT5Mco/+H6Q4yiI18MopOgUiJUeVuSoMrtVF+dzWjsVagbykjJioA8s9fdm6E=`). An
   unsigned index, an unknown key or a bad signature is refused; there is no option to skip this.
2. It refuses an index whose serial is lower than one it has already seen, so an old index
   cannot be replayed.
3. It downloads the SDK archive and the overlay. **Every file must have the exact size and
   SHA-256 from the index**, or it is deleted.
4. It installs into a temporary folder and moves it into place only when everything is verified.

If the network is down, the CLI uses the last verified copy of the index from its cache.

**Interrupted download?** Run `flutter_ota toolchain install` again. It resumes where it stopped
(HTTP `Range`; this works with the redirects GitHub release downloads use). A resumed file that
does not verify is downloaded once more from the start.

**The first store build** (`flutter_ota release android`) also downloads about 2 GB of Android
Gradle dependencies from the usual public repositories into the toolchain's own `gradle-home`.
Plan about 10 GB of free disk in total.

### 2.3 Upgrade

```bash
flutter_ota upgrade                # shows the current and the new toolchain, asks [y/N]
flutter_ota upgrade --yes          # in CI
```

Only after you answer yes does it install the new toolchain and rewrite `flutter_ota.lock`.
Without `--to <id>` it offers the newest toolchain the project can build with (see 2.1), and warns
when the project's Android build tools are below the new Flutter's minimums. `flutter_ota doctor`
checks them too.

A new toolchain means a **new store release**, because an installed app only runs patches built
with its own toolchain. **Existing store releases keep working:** `flutter_ota patch android
--release <id>` builds a patch for an older release with the toolchain that release was built with
(it installs it if needed), even after the project moved to a newer Flutter. See
[section 7](#7-flutter-upgrades).

### 2.4 Clean up

```bash
flutter_ota toolchain list         # installed toolchains; * marks this project's pin
flutter_ota toolchain clean        # deletes downloaded archives and leftovers
flutter_ota toolchain clean --unused   # also deletes toolchains no known project uses (asks first)
```

A toolchain is "in use" while a known project pins it **or one of the project's local store
releases (`.flutter_ota/releases/`) was built with it**, so `--unused` never removes the toolchain
you still need to patch an older release.

`--all` deletes every installed toolchain (it asks first; `--yes` skips the question). A deleted
toolchain is downloaded again by the next `toolchain install` or `release android`.

### 2.5 Private mirrors

You can serve the toolchain from your own server or folder, for example for machines without
internet access or for a toolchain you built yourself (section 6). Point the CLI at the mirror's
index and trust the public key that signed it:

```bash
flutter_ota config set toolchain-index-url https://mirror.example.com/index.json   # or file:///path/to/index.json
flutter_ota config add-toolchain-key <key_id> <public_key_base64>
flutter_ota toolchain install
```

Both the GitHub release layout (section 5) and the older mirror layout (`index.json` plus
`overlays/`) work, because relative URLs in the index are resolved against the index URL.
`FLUTTER_OTA_TOOLCHAIN_INDEX` overrides the setting for one shell. To go back to the official
index: `flutter_ota config unset toolchain-index-url`.

## 3. Formats

### 3.1 Toolchain index (signed)

The index is one JSON file. The CLI downloads it over `https://`, `file://` or
`http://localhost`.

```json
{
  "format": 1,
  "index": {
    "serial": 3,
    "toolchains": [
      {
        "id": "flutter-3.47.9-ota.1",
        "toolchain_id": "b59fbddd…",
        "flutter": "3.47.9",
        "dart": "3.13.7",
        "engine": "89c39edfdfae2949f6806e4a315c0c08522238b7",
        "dart_revision": "416e33b0ffaef062a60ec966bb8c82ed2b83f128",
        "host": "linux-x64",
        "target": "android-arm64",
        "artifacts": {
          "flutter_sdk": {"url": "https://…/flutter_linux_3.47.9-stable.tar.xz", "sha256": "…",
                          "size": 1582752184, "format": "tar.xz", "root": "flutter"},
          "overlay": {"url": "flutter-3.47.9-ota.1-linux-x64.tar.gz", "sha256": "…",
                      "size": 53806362, "unpacked_size": …, "format": "tar.gz"}
        }
      }
    ]
  },
  "signatures": [{"key_id": "…", "signature": "<base64 r||s>"}]
}
```

Rules:

- **Signature:** ES256 (ECDSA P-256 with SHA-256), raw `r||s`, base64. The signed message is the
  domain string `flutter-ota-system/toolchain-index/v1\n` followed by the **canonical JSON** of
  `index` (keys sorted, no spaces, integers only; the same encoding as
  `prototypes/security_hardening/tools/toolchain.py`).
- **Trusted keys:** the official key built into the CLI
  (`packages/flutter_ota_cli/lib/src/toolchain/trusted_keys.dart`), plus keys the user adds with
  `flutter_ota config add-toolchain-key`. An unsigned
  index, an unknown key or a bad signature is always refused. There is no option to skip
  verification.
- **Serial:** it must never go down. The CLI remembers the highest serial it has seen and refuses an
  older index, so an old signed index cannot be replayed.
- **Relative URLs** are resolved against the index URL, so a mirror is a plain copy of a folder.
- The newest toolchain is listed **last**.

### 3.2 `flutter_ota.lock`

Written by the CLI only (never edit it by hand):

```yaml
# Generated by flutter_ota. Do not edit by hand; use `flutter_ota upgrade`.
format: 1
toolchain: "flutter-3.47.9-ota.1"
toolchain_id: "b59fbdddabac06e97811e4b3c91ba28ea35f4fc8e075bfa48cc245831fdd7bd9"
flutter: "3.47.9"
dart: "3.13.7"
engine: "89c39edfdfae2949f6806e4a315c0c08522238b7"
dart_revision: "416e33b0ffaef062a60ec966bb8c82ed2b83f128"
```

- `toolchain install` writes it when the project has no lock yet.
- `toolchain install` refuses an index entry whose hashes differ from the lock.
- `upgrade` changes it only after confirmation.

### 3.3 Cache layout

Default `~/.cache/flutter_ota` (or `$XDG_CACHE_HOME/flutter_ota`; tests use `FLUTTER_OTA_CACHE`):

```text
toolchains/<id>/         installed toolchain
  flutter/               stock SDK with our gen_snapshot
  mirror/                Maven mirror (download.flutter.io/…)
  tools/*.aot            tool snapshots (dart2bytecode, pkg_rename, patch_guard, bc_verify)
  packages/dynamic_modules/  the module-loader package (copied into apps by release android)
  toolchain.json, overlay.json, NOTICES/
  install.json           written last: SHA-256 of every overlay file and key SDK files
  gradle-home/           isolated Gradle home (created by builds)
toolchains/.tmp-*        installs in progress
downloads/<sha256>       verified archives (removed by `toolchain clean`)
downloads/<sha256>.part  downloads in progress (resumed next time)
metadata/                last verified index, highest serial, projects that pin each toolchain
locks/<id>.lock          install lock (holds the process id)
```

## 4. How an install is protected

| Risk | What the CLI does |
| --- | --- |
| Changed or fake index | ES256 signature check with trusted keys only; old serials refused |
| Changed archive on the mirror | Size and SHA-256 must match the signed index; mismatches are deleted |
| Interrupted download | The `.part` file is kept and resumed (HTTP `Range`, or an offset for `file://`); a resumed file that does not verify is downloaded once more from the start |
| Corrupted cached archive | Every cached archive is hashed again before use and downloaded again if it does not match |
| Archive that cannot be extracted | Install stops, the cached archive is deleted, the temp folder is removed |
| Crash during install | Work happens in `toolchains/.tmp-…`; only a finished install is renamed into place; leftovers of dead processes are removed on the next install |
| Two installs at once | `locks/<id>.lock` holds the process id; a live holder blocks, a dead holder's lock is taken over |
| Disk full | Free space is checked before downloading and extracting (plus a 512 MB margin) |
| Overlay built for another SDK | The stock file it replaces must have the recorded SHA-256; `engine.version` must match the index |
| Wrong `toolchain.json` | Its content hash must equal `toolchain_id` in the index |
| Files changed after install | `toolchain doctor` and every resolve re-hash the files in `install.json` |

Archives are extracted with GNU `tar`, which refuses member names with `..`.

## 5. Owner: building and signing the release files

Requirements: the lab toolchain in `~/.cache/flutter-ota-lab` (see section 6). The script only
reads the lab, and uploads nothing.

```bash
cd flutter_ota_system                # your clone of the repository
RELEASE_LAYOUT=1 OUT=$HOME/flutter-ota-release ./tools/toolchain/build_bundle.sh   # GitHub release files
OUT=$HOME/flutter-ota-mirror ./tools/toolchain/build_bundle.sh                      # private mirror layout
```

With `RELEASE_LAYOUT=1`, all files are written flat into `OUT`: `toolchain-index.json`, the
overlay, `toolchain-manifest.json` and `SHA256SUMS` (section 2.1). Without it, `OUT` gets
`index.json` and `overlays/<id>-linux-x64.tar.gz`. The header comment of
`tools/toolchain/build_bundle.sh` lists every setting.

What it does:

1. Reads `prototypes/bytecode_engine/pins.env` (Flutter, engine and Dart revisions).
2. Looks up the official Flutter archive and its SHA-256 in the official `releases_linux.json`, and
   its size with an HTTP `HEAD` request. You can set `SDK_URL`, `SDK_SHA256` and `SDK_SIZE`
   yourself (for example to point at a local copy).
3. Creates the toolchain signing key on the first run, in `KEY_DIR` (default
   `~/.cache/flutter-ota-lab/keys/toolchain`). The script refuses a `KEY_DIR` inside the
   repository. **Never commit or share the `.key` file.**
4. Builds the overlay `<id>-linux-x64.tar.gz` reproducibly (sorted names, fixed dates and owners,
   `gzip -n`): the same lab gives the same SHA-256.
5. Writes and signs the index (other toolchains already in it are kept; the serial goes up by
   one), then verifies the result.
6. Prints the two commands developers run to use this mirror.

The official key's **public** key is in
`packages/flutter_ota_cli/lib/src/toolchain/trusted_keys.dart`; changing it needs a reviewed
commit and a new CLI version. Each CLI version pins the index URL of its own release.

## 6. Building the toolchain yourself

You can build everything from source and trust your own key instead of an official one. It needs a
Linux x86_64 machine, about 16 GB of disk for the engine source, and several hours. All steps use
scripts that already exist in the repository and write only into `$LAB`.

```bash
export LAB=$HOME/.cache/flutter-ota-lab
cd prototypes/bytecode_engine
source pins.env

# 1. Side-by-side Flutter at the pinned version (not your global Flutter).
git init -q $LAB/flutter && git -C $LAB/flutter remote add origin https://github.com/flutter/flutter.git
git -C $LAB/flutter fetch -q --depth 1 origin refs/tags/$FLUTTER_VERSION:refs/tags/$FLUTTER_VERSION
git -C $LAB/flutter checkout -q --detach $FLUTTER_VERSION
$LAB/flutter/bin/flutter --version

# 2. Engine source and build with the interpreter compiled in, then our Dart VM patch
#    (build_engine.sh needs the unmodified source, so the patch is applied afterwards).
./scripts/fetch_engine.sh
JOBS=4 ./scripts/build_engine.sh
../security_hardening/scripts/engine_patch.sh apply
../security_hardening/scripts/engine_patch.sh build

# 3. Install our gen_snapshot into the lab SDK and create the Maven mirror.
./scripts/prepare_toolchain.sh

# 4. Tool snapshots (dart2bytecode, pkg_rename, patch_guard, bc_verify).
DART=$LAB/flutter/bin/cache/dart-sdk/bin/dart
DART_SRC=$LAB/engine/engine/src/flutter/third_party/dart
mkdir -p $LAB/work/tools
for pair in "$DART_SRC/pkg/dart2bytecode/bin/dart2bytecode.dart:dart2bytecode" \
            "../real_app_compatibility/tools/pkg_rename/bin/pkg_rename.dart:pkg_rename" \
            "../security_hardening/tools/patch_guard/bin/patch_guard.dart:patch_guard" \
            "../security_hardening/tools/bc_verify/bin/bc_verify.dart:bc_verify"; do
  nice $DART compile aot-snapshot --packages="$DART_SRC/.dart_tool/package_config.json" \
    -o "$LAB/work/tools/${pair##*:}.aot" "${pair%:*}"
done

# 5. The content-hash toolchain record.
python3 -I ../security_hardening/tools/toolchain.py $LAB > $LAB/work/toolchain.json

# 6. Overlay, signed index, and trust your own key.
cd ../..
OUT=$HOME/flutter-ota-mirror ./tools/toolchain/build_bundle.sh
```

The last command prints the two `flutter_ota config` commands that point your CLI at your mirror
and trust your key.

## 7. Flutter upgrades

A toolchain matches exactly one Flutter / Dart / engine version. When a new Flutter version is
supported, the **project owner** (not each app developer) does this once:

1. pins the new Flutter, Dart and engine revisions;
2. ports and applies the engine changes (bytecode interpreter build flag, verifier patch);
3. builds the engine and the tools, runs the compatibility and security tests;
4. builds and signs a new overlay and index entry (section 5) and publishes it.

**Owner, several versions in one release:** build each toolchain into the same output folder with
the same key; the other entries of the index are kept and its serial goes up:

```bash
RELEASE_LAYOUT=1 OUT=$HOME/flutter_ota_release/<tag> KEY_DIR=… KEY_ID=… ./tools/toolchain/build_bundle.sh   # 3.47.9 lab
PINS_FILE=$PWD/prototypes/bytecode_engine/pins-3.50.0.env LAB=$HOME/.cache/flutter-ota-lab-350 \
  RELEASE_LAYOUT=1 OUT=$HOME/flutter_ota_release/<tag> KEY_DIR=… KEY_ID=… ./tools/toolchain/build_bundle.sh
```

**App developers, moving a project to a newer Flutter** (for example 3.47.9 → 3.50.0):

1. Raise the Android build tools to the new minimums (`flutter_ota doctor` lists them).
2. `flutter_ota upgrade` (asks before rewriting `flutter_ota.lock`). Use Flutter 3.50 for
   `flutter pub` and your IDE from now on.
3. `flutter_ota release android`: the next store release uses the new toolchain.

**Patching a store release made with the older Flutter** keeps working:
`flutter_ota patch android --release <id>` builds the patch with that release's toolchain. Two rules
protect the installed app:
- the patch is compared with the release's snapshot: raised Android build tool versions and the new
  `flutter_ota.lock` are ignored, other native or asset changes are refused;
- `pubspec.lock` must still be the release's: after `flutter pub get` with the new Flutter the
  versions differ, and `patch android` refuses ("pubspec.lock changed since the release").

So patch an older release from **that release's code**, for example a release branch or tag, where
`pubspec.lock` is still the release's. The release folder also keeps a copy
(`.flutter_ota/releases/<id>/pubspec.lock`).

Releases made with CLI 0.2.0-alpha.2 or earlier have no per-file snapshot hashes. For them, any
change to the Android build files also blocks a patch, so patch them from their own code as well.

## 8. Known limits

- Linux x64 hosts only. macOS and Windows would need separate engine host builds, which do not
  exist.
- Toolchains: Flutter 3.47.9 / Dart 3.13.7 (since v0.2.0-alpha) and Flutter 3.50.0 / Dart 3.14.0
  (since v0.3.0-alpha).
  - 3.50.0 was tested on an Android 14 x86_64 emulator with arm64 translation: release APK/AAB,
    patches, rollback, the malformed-patch corpus, and patching a 3.47.9 release after the project
    moved to 3.50.
  - On one physical Android 13 arm64 phone (release APK, a patch, rollback, and the B25/B27 and memory-fault malformed patches): same results as 3.47.9.
- The install was tested on Linux x64 with the official Flutter 3.47.9 archive downloaded over
  HTTPS: the download resumed after an interruption, `toolchain doctor` passed, and a release
  build of a new `flutter create` app worked and packaged the OTA `libflutter.so`.
- The first Gradle build needs internet access to the usual public repositories (about 2 GB into
  the toolchain's `gradle-home`).
