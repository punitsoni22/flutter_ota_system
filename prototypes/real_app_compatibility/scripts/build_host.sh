#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the Phase 2 host app (release, arm64) with the Phase 1 toolchain (custom engine, lab SDK)
# and records the baseline that modules are compiled against. The repository is not modified:
# app/ and packages/ are copied to $LAB/work/p2.
#
#   LAB=~/.cache/flutter-ota-lab [IFACE=full|core] ./scripts/build_host.sh
# Prints the baseline directory on the last line. Throttled for a shared workstation: nice, at
# most 2 Gradle workers, no Gradle/Kotlin daemons left running afterwards.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../../bytecode_engine/pins.env
source "$HERE/../bytecode_engine/pins.env"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
IFACE=${IFACE:-full}
SDK="$LAB/flutter"
OUT="$LAB/engine/engine/src/out/android_release_arm64"
OTA_APP_ID=${OTA_APP_ID:-7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5}
BASELINE_ID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
ROOT="$LAB/work/p2-$IFACE"
WORK="$ROOT/app"
export GRADLE_USER_HOME="$LAB/gradle"
export FLUTTER_STORAGE_BASE_URL="file://$LAB/mirror"

rm -rf "$ROOT" && mkdir -p "$ROOT"
(cd "$HERE" && tar --exclude=.dart_tool --exclude=build --exclude=pubspec.lock -cf - app packages) | tar -xf - -C "$ROOT"
cd "$WORK"
"$SDK/bin/flutter" create --suppress-analytics --platforms=android --org io.github.punitsoni22 \
  --project-name compat_host . >/dev/null
rm -rf test
cp "$HERE/app/android_overlay/MainActivity.kt" android/app/src/main/kotlin/io/github/punitsoni22/compat_host/MainActivity.kt
# Throttle Gradle on a shared machine.
sed -i 's/^org.gradle.jvmargs=.*/org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G/' android/gradle.properties
printf '%s\n' 'org.gradle.workers.max=2' 'org.gradle.daemon=false' 'kotlin.compiler.execution.strategy=in-process' >> android/gradle.properties
"$SDK/bin/flutter" pub get --suppress-analytics >/dev/null
python3 -I "$HERE/scripts/gen_interface.py" "$WORK/.dart_tool/package_config.json" "$IFACE" "$ROOT/dynamic_interface.yaml"

START=$(date +%s)
nice -n 10 "$SDK/bin/flutter" build apk --suppress-analytics --release --target-platform android-arm64 \
  --dart-define=OTA_APP_ID="$OTA_APP_ID" --dart-define=OTA_BASELINE_ID="$BASELINE_ID" \
  --extra-front-end-options=--dynamic-interface="$ROOT/dynamic_interface.yaml"
BUILD_SECONDS=$(( $(date +%s) - START ))
(cd android && GRADLE_USER_HOME="$LAB/gradle" ./gradlew --stop >/dev/null 2>&1 || true)

APK="$WORK/build/app/outputs/flutter-apk/app-release.apk"
DILL=$(find "$WORK/.dart_tool/flutter_build" -name app.dill | head -1)
[[ -s $APK && -s $DILL ]] || { echo "build outputs missing" >&2; exit 1; }

X=$(mktemp -d)
python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); [z.extract(n, sys.argv[2]) for n in ("lib/arm64-v8a/libflutter.so","lib/arm64-v8a/libapp.so")]' "$APK" "$X"
APK_ENGINE=$(sha256sum "$X/lib/arm64-v8a/libflutter.so" | cut -d' ' -f1)
OUR_ENGINE=$(sha256sum "$OUT/lib.stripped/libflutter.so" | cut -d' ' -f1)
[[ $APK_ENGINE == "$OUR_ENGINE" ]] || { echo "APK does not contain our libflutter.so" >&2; exit 1; }

BASE="$LAB/baselines/p2-$IFACE-$BASELINE_ID"
mkdir -p "$BASE"
# Link kernel (non-AOT, not tree-shaken) that modules are compiled against; see Phase 1 report.
nice -n 10 "$SDK/bin/cache/dart-sdk/bin/dartaotruntime" \
  "$SDK/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot" \
  --sdk-root "$SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/" \
  --target flutter --no-aot --no-tfa --no-link-platform \
  -DOTA_APP_ID="$OTA_APP_ID" -DOTA_BASELINE_ID="$BASELINE_ID" \
  --dynamic-interface "$ROOT/dynamic_interface.yaml" \
  --packages "$WORK/.dart_tool/package_config.json" \
  --output-dill "$BASE/link.dill" package:compat_host/main.dart >/dev/null
[[ -s $BASE/link.dill ]] || { echo "link kernel missing" >&2; exit 1; }
cp "$APK" "$BASE/app-release.apk"
cp "$X/lib/arm64-v8a/libapp.so" "$BASE/libapp.so"
cp "$ROOT/dynamic_interface.yaml" "$WORK/pubspec.lock" "$WORK/.dart_tool/package_config.json" "$BASE/"
# Snapshot of the exact sources this baseline was built from (modules compile against them).
mkdir -p "$BASE/src"
(cd "$ROOT" && tar --exclude=.dart_tool --exclude=build --exclude=android -cf - app packages) | tar -xf - -C "$BASE/src"
python3 -I - "$BASE" "$OTA_APP_ID" "$BASELINE_ID" "$ENGINE_COMMIT" "$APK_ENGINE" "$IFACE" "$BUILD_SECONDS" "$WORK" <<'PY'
import hashlib, json, sys, pathlib
base, app_id, baseline_id, engine_commit, engine_sha, iface, secs, work = sys.argv[1:]
p = lambda n: pathlib.Path(base, n)
h = lambda n: hashlib.sha256(p(n).read_bytes()).hexdigest()
json.dump({"app_id": app_id, "baseline_id": baseline_id, "runtime": "proto-dbc-flutter-3.47.9",
           "interface": iface, "work_dir": work, "engine_commit": engine_commit,
           "libflutter_sha256": engine_sha, "libapp_sha256": h("libapp.so"), "apk_sha256": h("app-release.apk"),
           "link_dill_sha256": h("link.dill"), "apk_bytes": p("app-release.apk").stat().st_size,
           "libapp_bytes": p("libapp.so").stat().st_size, "build_seconds": int(secs)},
          open(p("baseline.json"), "w"), indent=2)
PY
rm -rf "$X"
cat "$BASE/baseline.json"; echo
echo "$BASE"
