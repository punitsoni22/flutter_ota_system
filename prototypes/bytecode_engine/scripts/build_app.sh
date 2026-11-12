#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the BASELINE host app (release, arm64) with the prototype toolchain and records the
# baseline a patch must match. The repository is not modified: the app is copied to $LAB/work.
#
#   LAB=~/.cache/flutter-ota-lab [OTA_APP_ID=<uuid>] ./scripts/build_app.sh
# Prints the baseline directory on the last line.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../pins.env
source "$HERE/pins.env"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
SDK="$LAB/flutter"
OUT="$LAB/engine/engine/src/out/android_release_arm64"
# Prototype-only application identity (stands in for the server's application UUID).
OTA_APP_ID=${OTA_APP_ID:-0b5e6c1a-4f2d-4c8e-9a71-3d2f6e8b9c01}
BASELINE_ID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
WORK="$LAB/work/app"

rm -rf "$WORK" && mkdir -p "$WORK"
(cd "$HERE/app" && tar --exclude=.dart_tool --exclude=build --exclude=pubspec.lock -cf - .) | tar -xf - -C "$WORK"
cp "$HERE/dynamic_interface.yaml" "$LAB/work/dynamic_interface.yaml"
cd "$WORK"
"$SDK/bin/flutter" create --suppress-analytics --platforms=android --org io.github.punitsoni22 \
  --project-name bytecode_proto . >/dev/null
rm -rf test

# Isolated Gradle home + local Maven mirror: the engine can only come from our mirror.
export GRADLE_USER_HOME="$LAB/gradle"
export FLUTTER_STORAGE_BASE_URL="file://$LAB/mirror"
"$SDK/bin/flutter" build apk --suppress-analytics --release --target-platform android-arm64 \
  --dart-define=OTA_APP_ID="$OTA_APP_ID" --dart-define=OTA_BASELINE_ID="$BASELINE_ID" \
  --extra-front-end-options=--dynamic-interface="$LAB/work/dynamic_interface.yaml"

APK="$WORK/build/app/outputs/flutter-apk/app-release.apk"
DILL=$(find "$WORK/.dart_tool/flutter_build" -name app.dill | head -1)
[[ -s $APK && -s $DILL ]] || { echo "build outputs missing" >&2; exit 1; }

# Prove the APK carries OUR engine (interpreter-enabled), not a cached stock one.
X=$(mktemp -d)
python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); [z.extract(n, sys.argv[2]) for n in ("lib/arm64-v8a/libflutter.so","lib/arm64-v8a/libapp.so")]' "$APK" "$X"
APK_ENGINE=$(sha256sum "$X/lib/arm64-v8a/libflutter.so" | cut -d' ' -f1)
OUR_ENGINE=$(sha256sum "$OUT/lib.stripped/libflutter.so" | cut -d' ' -f1)
[[ $APK_ENGINE == "$OUR_ENGINE" ]] || { echo "APK does not contain our libflutter.so" >&2; exit 1; }

BASE="$LAB/baselines/$BASELINE_ID"
mkdir -p "$BASE"

# Link kernel: the release app.dill is a tree-shaken whole program and cannot be linked against.
# Compile the app's own libraries again WITHOUT AOT/TFA and without the platform, with the same
# defines and dynamic interface, using the SDK's stock frontend server.
"$SDK/bin/cache/dart-sdk/bin/dartaotruntime" \
  "$SDK/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot" \
  --sdk-root "$SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/" \
  --target flutter --no-aot --no-tfa --no-link-platform \
  -DOTA_APP_ID="$OTA_APP_ID" -DOTA_BASELINE_ID="$BASELINE_ID" \
  --dynamic-interface "$LAB/work/dynamic_interface.yaml" \
  --packages "$WORK/.dart_tool/package_config.json" \
  --output-dill "$BASE/link.dill" package:bytecode_proto/main.dart >/dev/null
[[ -s $BASE/link.dill ]] || { echo "link kernel missing" >&2; exit 1; }
cp "$APK" "$BASE/app-release.apk"
cp "$DILL" "$BASE/app.dill"
cp "$X/lib/arm64-v8a/libapp.so" "$BASE/libapp.so"
python3 -I - "$BASE" "$OTA_APP_ID" "$BASELINE_ID" "$ENGINE_COMMIT" "$APK_ENGINE" <<'EOF'
import hashlib, json, sys, pathlib
base, app_id, baseline_id, engine_commit, engine_sha = sys.argv[1:]
h = lambda p: hashlib.sha256(pathlib.Path(base, p).read_bytes()).hexdigest()
json.dump({"app_id": app_id, "baseline_id": baseline_id, "runtime": "proto-dbc-flutter-3.47.9",
           "engine_commit": engine_commit, "libflutter_sha256": engine_sha,
           "libapp_sha256": h("libapp.so"), "apk_sha256": h("app-release.apk"),
           "app_dill_sha256": h("app.dill"), "link_dill_sha256": h("link.dill")}, open(pathlib.Path(base, "baseline.json"), "w"), indent=2)
EOF
rm -rf "$X"
cat "$BASE/baseline.json"; echo
echo "$BASE"
