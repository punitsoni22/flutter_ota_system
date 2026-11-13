#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Applies, builds or reverts the Phase 3C Dart VM patch (engine_patch/0001-dart-bytecode-verifier.patch)
# on the pinned engine checkout in the lab. Nothing global is modified.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/engine_patch.sh apply|build|revert|status
#   apply   check the pinned Dart revision and a clean tree, then `git apply` the patch
#   build   incremental ninja build (same targets as bytecode_engine/scripts/build_engine.sh), -j3
#   revert  restore the unmodified upstream sources (git checkout + remove new files)
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../../bytecode_engine/pins.env
# PINS_FILE selects another pin set (see bytecode_engine/pins-*.env); the default is the baseline.
source "${PINS_FILE:-$HERE/../bytecode_engine/pins.env}"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
DART_DIR="$LAB/engine/engine/src/flutter/third_party/dart"
# The baseline patch is for BASE_DART_REVISION; a port for another Dart revision is named
# 0001-dart-bytecode-verifier-<first 7 characters of that revision>.patch.
PATCH="$HERE/engine_patch/0001-dart-bytecode-verifier.patch"
if [[ $DART_REVISION != "$(cat "$HERE/engine_patch/BASE_DART_REVISION")" ]]; then
  PATCH="$HERE/engine_patch/0001-dart-bytecode-verifier-${DART_REVISION:0:7}.patch"
  [[ -f $PATCH ]] || { echo "no verifier patch for Dart $DART_REVISION" >&2; exit 1; }
fi
OUT="$LAB/engine/engine/src/out/android_release_arm64"
NINJA="$LAB/engine/third_party/ninja/ninja"
NEW_FILES=(runtime/vm/bytecode_verifier.cc runtime/vm/bytecode_verifier.h)

[[ $(git -C "$DART_DIR" rev-parse HEAD) == "$DART_REVISION" ]] || { echo "Dart checkout is not at $DART_REVISION" >&2; exit 1; }
case ${1:-} in
  status)
    git -C "$DART_DIR" status --short ;;
  apply)
    if git -C "$DART_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then echo "patch already applied"; exit 0; fi
    [[ -z $(git -C "$DART_DIR" status --porcelain) ]] || { echo "Dart checkout has other local changes; refusing" >&2; exit 1; }
    git -C "$DART_DIR" apply "$PATCH"
    echo "applied: $(sha256sum "$PATCH" | cut -d' ' -f1)" ;;
  build)
    export PATH="$LAB/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
    cd "$LAB/engine/engine/src"
    /usr/bin/time -v nice -n 10 "$NINJA" -C "$OUT" -j"${JOBS:-3}" flutter/shell/platform/android:android_jar clang_x64/gen_snapshot
    sha256sum "$OUT/lib.stripped/libflutter.so" "$OUT/clang_x64/gen_snapshot" ;;
  revert)
    git -C "$DART_DIR" checkout -- runtime/vm/bytecode_reader.cc runtime/vm/interpreter.cc runtime/vm/vm_sources.gni
    for f in "${NEW_FILES[@]}"; do rm -f "$DART_DIR/$f"; done
    git -C "$DART_DIR" status --short ;;
  *) echo "usage: engine_patch.sh apply|build|revert|status" >&2; exit 2 ;;
esac
