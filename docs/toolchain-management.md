<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Toolchain management

Status: **experimental alpha, Phase 4 milestone 4B.** Linux x64 developer machines only. Tested
only with local `file://` mirrors and small test archives. No official toolchain is published yet:
publishing needs a separate owner approval.

This page explains:

1. what the OTA toolchain is;
2. how `flutter_ota` installs and checks it;
3. the index, lock file and cache formats;
4. how the owner builds and signs a toolchain bundle;
5. how a developer can build the toolchain themselves.

Commands are listed in [cli-reference-flutter-ota.md](cli-reference-flutter-ota.md).

## 1. What the toolchain is

Bytecode patches need a Flutter engine with the Dart bytecode interpreter compiled in
([ADR 0001 §11](architecture/adr/0001-bytecode-engine-and-developer-experience.md)). A toolchain is:

- a **stock Flutter SDK** (for example 3.47.9), downloaded from the official release archive;
- plus our **overlay**, a small archive (about 17 MB for 3.47.9) that contains:
  - our `gen_snapshot` (android-arm64-release, linux-x64 host), which replaces the stock one;
  - a local **Maven mirror** with our `libflutter.so` (inside the `arm64_v8a_release` jar), its POM,
    and the unmodified official embedding jar and POM;
  - four tool snapshots: `dart2bytecode`, `pkg_rename`, `patch_guard` and `bc_verify` (the
    reference bytecode verifier that `flutter_ota patch android` runs on every module);
  - the unchanged `dynamic_modules` package (`packages/dynamic_modules/`, from
    `prototypes/real_app_compatibility/packages/dynamic_modules`). Only a package with this name
    may call the Dart VM's module loader, so `flutter_ota release android` copies it into the app
    (see [releasing-with-flutter-ota.md](releasing-with-flutter-ota.md));
  - `toolchain.json`, the content-hash record of the toolchain (its `id` is the `toolchain_id`);
  - licence notices (Flutter and Dart are BSD-3-Clause; our tools are Apache-2.0).

The toolchain lives in the CLI's own cache. **Your global Flutter, your PATH, your Gradle cache and
your Android SDK are never used or changed.** Builds (later milestones) run the toolchain's own
`flutter` with:

```text
FLUTTER_STORAGE_BASE_URL=file://<toolchain>/mirror   # the engine can only come from our mirror
GRADLE_USER_HOME=<toolchain>/gradle-home             # no cached stock engine can be picked up
```

If the pinned toolchain is missing or fails verification, the CLI stops with a clear error. It
**never** falls back to a stock or global Flutter SDK.

## 2. Using it (developer)

```bash
# Once per machine: where the signed index is, and which key signs it.
flutter_ota config set toolchain-index-url file:///path/to/mirror/index.json
flutter_ota config add-toolchain-key <key_id> <public_key_base64>

# In your Flutter app:
flutter_ota init --app-id <server application UUID>
flutter_ota toolchain install      # downloads, verifies, installs, writes flutter_ota.lock
flutter_ota toolchain doctor       # checks the installed toolchain
```

Commit `flutter_ota.lock` with your app, so every developer and CI job uses the same toolchain.

To move to a newer toolchain, run `flutter_ota upgrade`. It shows the change and asks
`[y/N]`. Only after you answer yes does it install the new toolchain and rewrite
`flutter_ota.lock`. In CI, use `flutter_ota upgrade --yes`. Remember: a new toolchain means a new
store release, because patches only apply to apps built with the same toolchain.

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
          "overlay": {"url": "overlays/flutter-3.47.9-ota.1-linux-x64.tar.gz", "sha256": "…",
                      "size": 17961577, "unpacked_size": 41379840, "format": "tar.gz"}
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
- **Trusted keys:** the keys embedded in the CLI
  (`packages/flutter_ota_cli/lib/src/toolchain/trusted_keys.dart`, empty until the owner creates the
  official key), plus keys the user adds with `flutter_ota config add-toolchain-key`. An unsigned
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

## 5. Owner: building and signing a bundle

Requirements: the lab toolchain in `~/.cache/flutter-ota-lab` (see section 6). The script only
reads the lab.

```bash
cd ~/Desktop/flutter_ota_system      # your clone of the repository
OUT=$HOME/flutter-ota-mirror ./tools/toolchain/build_bundle.sh
```

What it does:

1. Reads `prototypes/bytecode_engine/pins.env` (Flutter, engine and Dart revisions).
2. Looks up the official Flutter archive and its SHA-256 in the official `releases_linux.json`, and
   its size with an HTTP `HEAD` request. You can set `SDK_URL`, `SDK_SHA256` and `SDK_SIZE`
   yourself (for example to point at a local copy).
3. Creates the toolchain signing key on the first run, in `KEY_DIR` (default
   `~/.cache/flutter-ota-lab/keys/toolchain`). The script refuses a `KEY_DIR` inside the
   repository. **Never commit or share the `.key` file.**
4. Builds `overlays/<id>-linux-x64.tar.gz` reproducibly (sorted names, fixed dates and owners,
   `gzip -n`): the same lab gives the same SHA-256.
5. Writes and signs `index.json` (other toolchains already in it are kept; the serial goes up by
   one), then verifies the result.
6. Prints the two commands developers run to use this mirror.

To make a key official, add its **public** key to
`packages/flutter_ota_cli/lib/src/toolchain/trusted_keys.dart` in a reviewed commit. Publishing a
mirror (for example on GitHub Releases) needs the owner's approval.

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

## 7. Known limits (milestone 4B)

- Linux x64 hosts only. macOS and Windows would need separate engine host builds, which do not
  exist.
- Tested only with small test archives and local `file://` mirrors. A full install from the real
  1.5 GB Flutter archive has not been run yet.
- Not yet checked: whether the official Flutter 3.47.9 archive already contains the
  `android-arm64-release` `gen_snapshot` that the overlay replaces. If it does not, the install
  stops with "The stock SDK has no …", and the overlay must also carry those Android engine
  artifacts.
- The first `flutter` run inside the installed SDK may still try to download other engine
  artifacts; with the mirror setting, that would fail. To be checked in milestone 4D (release
  builds).
- No official signing key and no published index exist yet.
