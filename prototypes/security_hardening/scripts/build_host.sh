#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the Phase 3 host: the Phase 2 host app (../real_app_compatibility) plus the Phase 3
# overlay (secure runtime, isolated verifier process) and package:patch_security, with the Phase 1
# toolchain. Records the baseline modules and patches are built against.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/build_host.sh
# Test signing keys are created under $LAB/keys/p3 (never in the repository): p3-dev-1 and
# p3-dev-2 are trusted by the build, p3-rogue is not. Prints the baseline directory last.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
P2="$HERE/../real_app_compatibility"
# shellcheck source=../../bytecode_engine/pins.env
source "$HERE/../bytecode_engine/pins.env"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
SDK="$LAB/flutter"
OUT="$LAB/engine/engine/src/out/android_release_arm64"
OTA_APP_ID=${OTA_APP_ID:-7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5}
BASELINE_ID=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
ROOT="$LAB/work/p3"
WORK="$ROOT/app"
KEYS="$LAB/keys/p3"
export GRADLE_USER_HOME="$LAB/gradle"
export FLUTTER_STORAGE_BASE_URL="file://$LAB/mirror"

for k in p3-dev-1 p3-dev-2 p3-rogue; do
  [[ -f $KEYS/$k.pem ]] || python3 -I "$HERE/tools/sign_patch.py" keygen --dir "$KEYS" --key-id "$k" >/dev/null
done
PUBLIC_KEYS=$(python3 -I -c 'import json,sys; d=sys.argv[1]; print(json.dumps({k: open(f"{d}/{k}.pub").read().strip() for k in ("p3-dev-1","p3-dev-2")}, separators=(",",":")))' "$KEYS")
RUNTIME=$(printf '{"abi":"android-arm64","dart":"%s","engine":"%s","flutter":"%s","runtime_id":"proto-dbc-flutter-%s"}' "$DART_VERSION" "${ENGINE_COMMIT:0:8}" "$FLUTTER_VERSION" "$FLUTTER_VERSION")

rm -rf "$ROOT" && mkdir -p "$ROOT/packages"
(cd "$P2" && tar --exclude=.dart_tool --exclude=build --exclude=pubspec.lock -cf - app packages) | tar -xf - -C "$ROOT"
(cd "$HERE/packages" && tar --exclude=.dart_tool --exclude=pubspec.lock -cf - patch_security) | tar -xf - -C "$ROOT/packages"
cp "$HERE"/host_overlay/lib/*.dart "$WORK/lib/"
rm -f "$WORK/lib/probe_runner.dart"   # Phase 3: no unsigned module loading
python3 -I - "$WORK/pubspec.yaml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("  dynamic_modules:\n", "  patch_security:\n    path: ../packages/patch_security\n  dynamic_modules:\n", 1)
p.write_text(s)
PY
cd "$WORK"
"$SDK/bin/flutter" create --suppress-analytics --platforms=android --org io.github.punitsoni22 \
  --project-name compat_host . >/dev/null
rm -rf test
KT=android/app/src/main/kotlin/io/github/punitsoni22/compat_host
cp "$HERE/host_overlay/android/MainActivity.kt" "$HERE/host_overlay/android/VerifierService.kt" "$KT/"
python3 -I - android/app/src/main/AndroidManifest.xml <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
svc = '        <service android:name=".VerifierService" android:process=":otaverify" android:exported="false" />\n'
if 'VerifierService' not in s:
    s = s.replace('    </application>', svc + '    </application>', 1)
p.write_text(s)
PY
sed -i 's/^org.gradle.jvmargs=.*/org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G/' android/gradle.properties
printf '%s\n' 'org.gradle.workers.max=2' 'org.gradle.daemon=false' 'kotlin.compiler.execution.strategy=in-process' >> android/gradle.properties
"$SDK/bin/flutter" pub get --suppress-analytics >/dev/null
python3 -I "$P2/scripts/gen_interface.py" "$WORK/.dart_tool/package_config.json" full "$ROOT/dynamic_interface.yaml"
IFACE_SHA=$(sha256sum "$ROOT/dynamic_interface.yaml" | cut -d' ' -f1)
HOST_PACKAGES=$(python3 -I -c 'import json,sys; print(";".join(sorted(p["name"] for p in json.load(open(sys.argv[1]))["packages"])))' "$WORK/.dart_tool/package_config.json")
# Defines must not contain commas (both flutter --dart-define and frontend_server -D split on
# them): JSON values are base64-encoded, lists use ';'.
b64() { printf '%s' "$1" | base64 -w0; }
DEFINES=(--dart-define=OTA_APP_ID="$OTA_APP_ID" --dart-define=OTA_BASELINE_ID="$BASELINE_ID"
  --dart-define=OTA_PUBLIC_KEYS_B64="$(b64 "$PUBLIC_KEYS")" --dart-define=OTA_INTERFACE_SHA256="$IFACE_SHA"
  --dart-define=OTA_HOST_PACKAGES="$HOST_PACKAGES" --dart-define=OTA_RUNTIME_B64="$(b64 "$RUNTIME")")

START=$(date +%s)
nice -n 10 "$SDK/bin/flutter" build apk --suppress-analytics --release --target-platform android-arm64 \
  "${DEFINES[@]}" --extra-front-end-options=--dynamic-interface="$ROOT/dynamic_interface.yaml"
BUILD_SECONDS=$(( $(date +%s) - START ))
(cd android && ./gradlew --stop >/dev/null 2>&1 || true)

APK="$WORK/build/app/outputs/flutter-apk/app-release.apk"
[[ -s $APK ]] || { echo "APK missing" >&2; exit 1; }
X=$(mktemp -d)
python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); [z.extract(n, sys.argv[2]) for n in ("lib/arm64-v8a/libflutter.so","lib/arm64-v8a/libapp.so")]' "$APK" "$X"
APK_ENGINE=$(sha256sum "$X/lib/arm64-v8a/libflutter.so" | cut -d' ' -f1)
[[ $APK_ENGINE == "$(sha256sum "$OUT/lib.stripped/libflutter.so" | cut -d' ' -f1)" ]] || { echo "APK does not contain our libflutter.so" >&2; exit 1; }

BASE="$LAB/baselines/p3-$BASELINE_ID"
mkdir -p "$BASE/src"
DEFINE_FLAGS=()
for d in "${DEFINES[@]}"; do DEFINE_FLAGS+=("-D${d#--dart-define=}"); done
nice -n 10 "$SDK/bin/cache/dart-sdk/bin/dartaotruntime" \
  "$SDK/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot" \
  --sdk-root "$SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/" \
  --target flutter --no-aot --no-tfa --no-link-platform "${DEFINE_FLAGS[@]}" \
  --dynamic-interface "$ROOT/dynamic_interface.yaml" \
  --packages "$WORK/.dart_tool/package_config.json" \
  --output-dill "$BASE/link.dill" package:compat_host/main.dart >/dev/null
cp "$APK" "$BASE/app-release.apk"
cp "$X/lib/arm64-v8a/libapp.so" "$BASE/libapp.so"
cp "$ROOT/dynamic_interface.yaml" "$WORK/pubspec.lock" "$BASE/"
(cd "$ROOT" && tar --exclude=.dart_tool --exclude=build --exclude=android -cf - app packages) | tar -xf - -C "$BASE/src"
python3 -I - "$BASE" "$OTA_APP_ID" "$BASELINE_ID" "$ENGINE_COMMIT" "$APK_ENGINE" "$IFACE_SHA" "$RUNTIME" "$HOST_PACKAGES" "$BUILD_SECONDS" <<'PY'
import hashlib, json, sys, pathlib
base, app_id, baseline_id, engine_commit, engine_sha, iface, runtime, host_pkgs, secs = sys.argv[1:]
p = lambda n: pathlib.Path(base, n)
h = lambda n: hashlib.sha256(p(n).read_bytes()).hexdigest()
internal = sorted(d.name for d in pathlib.Path(base, "src/packages").iterdir() if d.is_dir())
json.dump({"internal": internal, "all": host_pkgs.split(";")}, open(p("host_packages.json"), "w"), indent=2)
json.dump({"app_id": app_id, "baseline_id": baseline_id, "runtime": "proto-dbc-flutter-3.47.9",
           "runtime_info": json.loads(runtime), "interface_sha256": iface, "engine_commit": engine_commit,
           "libflutter_sha256": engine_sha, "libapp_sha256": h("libapp.so"), "apk_sha256": h("app-release.apk"),
           "link_dill_sha256": h("link.dill"), "apk_bytes": p("app-release.apk").stat().st_size,
           "libapp_bytes": p("libapp.so").stat().st_size, "build_seconds": int(secs)},
          open(p("baseline.json"), "w"), indent=2)
PY
rm -rf "$X"
cat "$BASE/baseline.json"; echo
echo "$BASE"
