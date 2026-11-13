#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the Android arm64 release engine (libflutter.so) and its gen_snapshot from the pinned,
# UNMODIFIED source, with one change: the official GN flag that compiles the Dart VM's bytecode
# interpreter in (`--dart-dynamic-modules`). Low parallelism by default to limit memory use.
#
#   LAB=~/.cache/flutter-ota-lab JOBS=4 ./scripts/build_engine.sh
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../pins.env
# PINS_FILE selects another pin set (for example pins-3.50.0.env); the default is the baseline.
source "${PINS_FILE:-$HERE/pins.env}"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
JOBS=${JOBS:-4}
ENGINE="$LAB/engine"
SRC="$ENGINE/engine/src"
export DEPOT_TOOLS_UPDATE=0
# depot_tools provides vpython3, used by GN and by build actions. Its ninja wrapper needs a
# bootstrap we skip (no auto-update), so the engine's own pinned ninja binary is called directly.
export PATH="$LAB/depot_tools:$PATH"

[[ $(git -C "$ENGINE" rev-parse HEAD) == "$ENGINE_COMMIT" ]] || { echo "engine checkout is not at the pinned commit" >&2; exit 1; }
[[ -z $(git -C "$ENGINE" status --porcelain --untracked-files=no) ]] || { echo "engine checkout has source edits" >&2; exit 1; }
[[ -z $(git -C "$SRC/flutter/third_party/dart" status --porcelain --untracked-files=no) ]] || { echo "Dart checkout has source edits" >&2; exit 1; }

cd "$SRC"
# Android SDK: the engine's pinned bundle (third_party/android_tools/sdk) when present. Otherwise
# ANDROID_SDK_REUSE=<existing SDK> (see fetch_engine.sh) is used read-only. Note: the engine always
# takes the NDK from //flutter/third_party/android_tools/sdk/ndk/<version> (android_ndk_root is not
# a build argument), so with ANDROID_SDK_REUSE that path must point at the reused SDK's NDK.
SDK_ARGS=()
PINNED_SDK="$SRC/flutter/third_party/android_tools/sdk"
if [[ -f $PINNED_SDK/ndk/28.2.13676358/source.properties && -d $PINNED_SDK/build-tools/36.1.0 ]]; then
  echo "using the engine's pinned Android SDK bundle"
elif [[ -n ${ANDROID_SDK_REUSE:-} ]]; then
  BT=${ANDROID_BUILD_TOOLS:-36.0.0}
  [[ -d $ANDROID_SDK_REUSE/build-tools/$BT ]] || { echo "missing build-tools $BT" >&2; exit 1; }
  SDK_ARGS=(--gn-args="android_sdk_root=\"$ANDROID_SDK_REUSE\""
            --gn-args="android_sdk_build_tools_version=\"$BT\"")
fi
./flutter/tools/gn --android --android-cpu arm64 --runtime-mode release \
  --no-prebuilt-dart-sdk --dart-dynamic-modules "${SDK_ARGS[@]}"
OUT=out/android_release_arm64
grep -qx 'dart_dynamic_modules = true' "$OUT/args.gn" || { echo "dart_dynamic_modules is not enabled" >&2; exit 1; }
# The engine's own pinned ninja (depot_tools' wrapper needs a bootstrap we skip).
NINJA="$ENGINE/third_party/ninja/ninja"
/usr/bin/time -v "$NINJA" -C "$OUT" -j"$JOBS" flutter/shell/platform/android:android_jar clang_x64/gen_snapshot \
  2> >(tee "$LAB/build_engine.time" >&2)
for f in libflutter.so lib.stripped/libflutter.so clang_x64/gen_snapshot; do
  [[ -s $OUT/$f ]] || { echo "missing build output $f" >&2; exit 1; }
done
"$OUT/clang_x64/gen_snapshot" --version
sha256sum "$OUT/lib.stripped/libflutter.so" "$OUT/clang_x64/gen_snapshot"
du -sh "$OUT"
