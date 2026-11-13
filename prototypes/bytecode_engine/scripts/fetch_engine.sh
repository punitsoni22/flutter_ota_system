#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Checks out the pinned, unmodified Flutter engine source (with its Dart SDK) into the lab
# directory. Nothing is installed globally: depot_tools is cloned into the lab and put on PATH
# for this process only.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/fetch_engine.sh
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../pins.env
# PINS_FILE selects another pin set (for example pins-3.50.0.env); the default is the baseline.
source "${PINS_FILE:-$HERE/pins.env}"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
DEPOT="$LAB/depot_tools"
ENGINE="$LAB/engine"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo "needs Linux x86_64" >&2; exit 1; }
mkdir -p "$LAB"

if [[ ! -d $DEPOT ]]; then
  git clone --quiet https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT"
fi
# Pin depot_tools to the revision recorded in pins.env (it is not auto-updated afterwards).
if [[ -n ${DEPOT_TOOLS_REV:-} && $(git -C "$DEPOT" rev-parse HEAD) != "$DEPOT_TOOLS_REV" ]]; then
  git -C "$DEPOT" fetch --quiet origin "$DEPOT_TOOLS_REV"
  git -C "$DEPOT" checkout --quiet --detach "$DEPOT_TOOLS_REV"
fi
git -C "$DEPOT" rev-parse HEAD > "$LAB/depot_tools.rev"
export DEPOT_TOOLS_UPDATE=0
export PATH="$DEPOT:$PATH"

if [[ ! -d $ENGINE/.git ]]; then
  git init --quiet "$ENGINE"
  git -C "$ENGINE" remote add origin https://github.com/flutter/flutter.git
fi
# Refuse to touch a checkout with local edits.
if git -C "$ENGINE" rev-parse --verify HEAD >/dev/null 2>&1; then
  [[ -z $(git -C "$ENGINE" status --porcelain --untracked-files=no) ]] || { echo "engine checkout has edits" >&2; exit 1; }
fi
git -C "$ENGINE" fetch --quiet --depth 1 origin "$ENGINE_COMMIT"
git -C "$ENGINE" checkout --quiet --detach "$ENGINE_COMMIT"
[[ $(git -C "$ENGINE" rev-parse HEAD) == "$ENGINE_COMMIT" ]]
# Same solution as engine/scripts/standard.gclient, plus:
#  - Fuchsia SDK/tools are never needed for an Android build: skipped.
#  - Optional ANDROID_SDK_REUSE=<existing Android SDK>: skip the engine's pinned Android SDK/NDK
#    bundle and use that SDK read-only (build_engine.sh passes it via --gn-args). It must contain
#    exactly the NDK version the engine pins and SDK platform 36.
SKIP_DEPS='"engine/src/flutter/tools/fuchsia/test_scripts": None, "engine/src/flutter/tools/fuchsia/gn-sdk": None,'
if [[ -n ${ANDROID_SDK_REUSE:-} ]]; then
  [[ -d $ANDROID_SDK_REUSE/ndk/28.2.13676358 && -f $ANDROID_SDK_REUSE/platforms/android-36/android.jar ]] || {
    echo "ANDROID_SDK_REUSE lacks ndk/28.2.13676358 or platforms/android-36" >&2; exit 1; }
  SKIP_DEPS+=' "engine/src/flutter/third_party/android_tools": None, "engine/src/flutter/third_party/android_tools/trace_to_text": None,'
fi
cat > "$ENGINE/.gclient" <<EOF
solutions = [{
  "name": ".", "url": "https://github.com/flutter/flutter.git", "deps_file": "DEPS",
  "managed": False, "safesync_url": "",
  "custom_deps": {${SKIP_DEPS}},
  "custom_vars": {"download_fuchsia_deps": False},
}]
EOF
cd "$ENGINE"
gclient sync -D --no-history
DART_DIR="$ENGINE/engine/src/flutter/third_party/dart"
[[ $(git -C "$DART_DIR" rev-parse HEAD) == "$DART_REVISION" ]] || { echo "unexpected Dart revision" >&2; exit 1; }
echo "engine $ENGINE_COMMIT, dart $DART_REVISION, depot_tools $(cat "$LAB/depot_tools.rev")"
du -sh "$LAB"
