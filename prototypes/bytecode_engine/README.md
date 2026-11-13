# Bytecode engine prototype (Phase 1)

An isolated proof of concept: a Flutter Android app whose pure-Dart package is replaced at the next
cold start by **Dart bytecode run by the Dart VM's interpreter**, without reinstalling the APK and
without replacing `libapp.so`.

> [!WARNING]
> Research prototype. Not part of the Flutter OTA System product, not production code, no
> signatures (integrity and identity checks only), fixed paths, one patchable package. The engine
> uses an experimental, unsupported Dart feature. The product architecture built on it is
> described in [docs/architecture.md](../../docs/architecture.md); the Phase 1 report is kept in
> the Git history.

## What is here

| Path | Purpose |
|---|---|
| `pins.env` | Pinned Flutter 3.47.9, engine and Dart revisions |
| `scripts/fetch_engine.sh` | Checks out the unmodified engine source (with Dart) into the lab directory |
| `scripts/build_engine.sh` | Builds `libflutter.so` + `gen_snapshot` for Android arm64 release with `--dart-dynamic-modules` |
| `scripts/prepare_toolchain.sh` | Installs our `gen_snapshot` into the lab SDK and creates a local Maven mirror with our engine |
| `scripts/build_app.sh` | Builds the baseline host app and records the baseline (app.dill, identity, hashes) |
| `scripts/make_patch.sh` | Compiles `patch/greeting_v2` to a bytecode module and packages a `.otp` patch |
| `scripts/patch_variants.py` | Produces the invalid patches for the negative tests |
| `scripts/device_tests.sh` | Runs all scenarios on a device/emulator and records evidence |
| `app/` | Host app: `package:greeting` (v1, AOT), the loader, and our `dynamic_modules` wrapper |
| `patch/greeting_v2/` | Version 2 of the package (renamed `greeting_patch`) + module entry point |
| `dynamic_interface.yaml` | Host libraries a module may use (none beyond `dart:core` here) |

## Requirements

- Linux x86_64, ~25 GB free disk for the lab (measured: 16 GB checkout + build outputs), 8 GB+
  free RAM recommended (build uses `JOBS` parallel jobs, default 4).
- `git`, `python3`, `curl`, Java (Flutter's configured JDK), Android SDK platform tools (`adb`).
- An arm64 Android device, or an x86_64 emulator image with ARM translation (API 30+ Google images).

Nothing is installed globally: everything goes into `$LAB` (default `~/.cache/flutter-ota-lab`),
including a side-by-side Flutter 3.47.9 and depot_tools. Your own Flutter, PATH, Java, Gradle and
Android SDK are not modified.

## Reproduce

```bash
cd prototypes/bytecode_engine
export LAB=$HOME/.cache/flutter-ota-lab
source pins.env

# 1. Side-by-side Flutter 3.47.9 (pinned commit)
git init -q $LAB/flutter && git -C $LAB/flutter remote add origin https://github.com/flutter/flutter.git
git -C $LAB/flutter fetch -q --depth 1 origin refs/tags/$FLUTTER_VERSION:refs/tags/$FLUTTER_VERSION
git -C $LAB/flutter checkout -q --detach $FLUTTER_VERSION
$LAB/flutter/bin/flutter --version

# 2. Engine source (unmodified) and build with the interpreter compiled in
./scripts/fetch_engine.sh                 # ~16 GB; add ANDROID_SDK_REUSE=<sdk> to skip the SDK bundle
JOBS=6 ./scripts/build_engine.sh

# 3. Toolchain, baseline app, patch
./scripts/prepare_toolchain.sh
BASE=$(./scripts/build_app.sh | tail -1)
./scripts/make_patch.sh "$BASE" 1 $LAB/work/patch1.otp
python3 -I scripts/patch_variants.py $LAB/work/patch1.otp $LAB/work/variants

# 4. Device or emulator tests (adb must see exactly one device)
./scripts/device_tests.sh "$BASE" $LAB/work/patch1.otp $LAB/work/variants $LAB/results
```

## How it works

1. The host app depends on `package:greeting` (v1). It is compiled ahead of time into `libapp.so`.
2. At start, `lib/patch_loader.dart` looks for a patch in the app's external files inbox
   (`/sdcard/Android/data/io.github.punitsoni22.bytecode_proto/files/inbox/patch.otp`), validates
   it (magic, format, runtime, app id, baseline id, patch number, size, SHA-256) and moves it to
   private storage. Every start re-validates the stored patch.
3. The module is loaded with `dart:_internal.loadDynamicModule` through our `dynamic_modules`
   package. Its `@pragma('dyn-module:entry-point')` returns the v2 `greeting` function, which the
   host calls instead of v1. Patched code runs in the **Dart VM bytecode interpreter**.
4. A boot-attempt marker drops a patch whose start never confirms; any load error falls back to the
   baseline. `inbox/ROLLBACK` removes the active patch.

Patch file (`.otp`): `"OTAPRT01"` · u32 big-endian manifest length · manifest JSON · module bytes.

## Limitations

See the Phase 1 report. In short: one pure-Dart package; the module only uses `dart:core`; no
signature; delivery by `adb push`; Android arm64 only; experimental upstream Dart feature.

Copyright 2026 The Punit Authors. Apache-2.0. Flutter and Dart are BSD-3-Clause; flutter_patcher
(MIT) was used as a technical reference only, and no code was copied from it.
