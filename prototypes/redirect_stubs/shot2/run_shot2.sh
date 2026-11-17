#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
# Shot 2: the redirect patch engine on a real Android phone, in one run.
#
#   store release (instrumented) -> install -> run v1 -> patch to v2 -> download -> run patched
#   -> compare every case with the real v2 -> start-up, check cost, sizes -> one report
#
# Runs on the Linux x64 build machine with an arm64 phone on USB. See SHOT2.md.
#
#   APP_ID=<server app uuid> FLUTTER_OTA_ADMIN_KEY=<admin key> ./run_shot2.sh [redirect|redirect-fast|plain]
#
# Modes:
#   redirect       every function gets a check (default)
#   redirect-fast  tiny leaf functions get no check (--skip-leaves)
#   plain          the feature engine (no checks): the baseline for start-up, check cost and size.
#                  No patch is made in this mode.
#
# Optional environment:
#   WORK         work folder (default: ~/ota_shot2)
#   SERVER_URL   server as the phone and this machine see it (default: http://localhost:8000; the
#                phone reaches it through `adb reverse`)
#   ANDROID_SERIAL  phone to use when several are connected
#   STARTS       cold starts measured per state (default: 5)
#   SKIP_CLI_ACTIVATE=1  use the flutter_ota already on PATH instead of this checkout's CLI

set -euo pipefail

MODE="${1:-redirect}"
case "$MODE" in redirect|redirect-fast|plain) ;; *) echo "unknown mode $MODE" >&2; exit 64 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUBS="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$STUBS/../.." && pwd)"
WORK="${WORK:-$HOME/ota_shot2}"
APP="$WORK/app"
SERVER_URL="${SERVER_URL:-http://localhost:8000}"
STARTS="${STARTS:-5}"
PKG="dev.example.ota_shot2"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$WORK/results/$MODE-$STAMP"
export FLUTTER_OTA_REDIRECT_TOOL="$STUBS/tool"

: "${APP_ID:?set APP_ID to the server application UUID (see SHOT2.md)}"
: "${FLUTTER_OTA_ADMIN_KEY:?set FLUTTER_OTA_ADMIN_KEY to the server admin key}"

mkdir -p "$OUT"
log() { printf '\n== %s\n' "$*" | tee -a "$OUT/steps.log"; }
die() { echo "FAILED: $*" | tee -a "$OUT/steps.log" >&2; exit 1; }
for t in adb python3 unzip; do command -v "$t" >/dev/null || die "$t is not installed"; done

# ---------------------------------------------------------------- CLI from this checkout
if [[ "${SKIP_CLI_ACTIVATE:-0}" != 1 ]]; then
  log "Activating the flutter_ota CLI of this checkout"
  command -v dart >/dev/null || die "dart is not on PATH (needed once to activate the CLI)"
  dart pub global activate --source path "$REPO/packages/flutter_ota_cli" >>"$OUT/steps.log" 2>&1
  export PATH="$PATH:${PUB_CACHE:-$HOME/.pub-cache}/bin"
fi
command -v flutter_ota >/dev/null || die "flutter_ota is not on PATH"

# ---------------------------------------------------------------- app (created once)
set_cases() { # v1 | v2: the test cases in the app
  rm -rf "$APP/lib/src" "$APP/lib/cases.dart"
  cp -R "$STUBS/cases/$1/lib/src" "$APP/lib/src"
  cp "$STUBS/cases/$1/lib/cases.dart" "$APP/lib/cases.dart"
}

toolchain_flutter() {
  local tc
  tc="$(sed -n 's/^toolchain: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$APP/flutter_ota.lock" | head -1)"
  local f="${FLUTTER_OTA_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/flutter_ota}/toolchains/$tc/flutter/bin/flutter"
  [[ -x "$f" ]] || die "toolchain Flutter not found at $f"
  echo "$f"
}

if [[ ! -f "$APP/flutter_ota.yaml" ]]; then
  log "Creating the test app in $APP"
  mkdir -p "$APP"
  cp -R "$HERE/app/." "$APP/"
  sed -i "s|path: ../../../../packages/ota_client|path: $REPO/packages/ota_client|" "$APP/pubspec.yaml"
  set_cases v1
  (cd "$APP" && flutter_ota init --app-id "$APP_ID") | tee -a "$OUT/steps.log"
  (cd "$APP" && flutter_ota toolchain install) 2>&1 | tee -a "$OUT/steps.log"
  FLUTTER="$(toolchain_flutter)"
  (cd "$APP" && "$FLUTTER" create --platforms android --project-name ota_shot2 --org dev.example . ) >>"$OUT/steps.log" 2>&1
  rm -rf "$APP/test"
  # arm64 only (the OTA engine exists for arm64-v8a only).
  perl -0pi -e 's/(defaultConfig \{\n)/$1        ndk {\n            abiFilters.clear()\n            abiFilters += "arm64-v8a"\n        }\n/' \
    "$APP/android/app/build.gradle.kts"
  grep -q 'arm64-v8a' "$APP/android/app/build.gradle.kts" || die "could not add abiFilters to build.gradle.kts"
fi
FLUTTER="$(toolchain_flutter)"
DART="$(dirname "$FLUTTER")/dart"
cd "$APP"
(flutter_ota keys init --server-url "$SERVER_URL") >>"$OUT/steps.log" 2>&1 || die "keys init failed (see $OUT/steps.log)"

# ---------------------------------------------------------------- phone
ADB=(adb ${ANDROID_SERIAL:+-s "$ANDROID_SERIAL"})
"${ADB[@]}" get-state >/dev/null 2>&1 || die "no phone found by adb"
abi="$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"
[[ "$abi" == arm64* ]] || die "the phone is not arm64 ($abi)"
if [[ "$SERVER_URL" == http://localhost:* || "$SERVER_URL" == http://127.0.0.1:* ]]; then
  port="${SERVER_URL##*:}"; port="${port%%/*}"
  "${ADB[@]}" reverse "tcp:$port" "tcp:$port" >/dev/null
fi
{
  echo "phone: $("${ADB[@]}" shell getprop ro.product.manufacturer | tr -d '\r') $("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')"
  echo "android: $("${ADB[@]}" shell getprop ro.build.version.release | tr -d '\r') (sdk $("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r'))"
} | tee "$OUT/phone.txt"

launch() { # name: one cold start; waits for the cases, or for the bench when $2 = bench
  local name="$1" until="${2:-cases}" pattern
  pattern='\[shot2\] cases_done'; [[ "$until" == bench ]] && pattern='\[shot2\] bench_done'
  "${ADB[@]}" shell am force-stop "$PKG"
  "${ADB[@]}" logcat -c
  "${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  local end=$((SECONDS + 150))
  # Read the log into a file first: with pipefail, `logcat | grep -q` can fail after a match.
  while true; do
    "${ADB[@]}" logcat -d -v raw -s flutter:I >"$OUT/$name.log"
    grep -q "$pattern" "$OUT/$name.log" && break
    (( SECONDS < end )) || { "${ADB[@]}" logcat -d >"$OUT/$name.full.log"; die "$name: no '$pattern' within 150 s (see $name.full.log)"; }
    sleep 2
  done
  # Leave the app running past the stable period before the next force-stop, so crash protection
  # never counts a test stop as a failed start.
  [[ "$until" == bench ]] || sleep 15
  grep '\[shot2\] start' "$OUT/$name.log" | tail -1 | tee -a "$OUT/steps.log"
}

starts() { # label: STARTS cold starts, start lines collected in <label>_starts.txt
  : >"$OUT/$1_starts.txt"
  for i in $(seq 1 "$STARTS"); do
    launch "$1_start$i" >/dev/null
    grep '\[shot2\] start' "$OUT/$1_start$i.log" | tail -1 >>"$OUT/$1_starts.txt"
  done
}

# ---------------------------------------------------------------- store release
log "Store release ($MODE)"
set_cases v1
engine=(--engine redirect); [[ "$MODE" == redirect-fast ]] && engine+=(--skip-leaves); [[ "$MODE" == plain ]] && engine=(--engine feature)
build_number=$(( $(date +%s) / 60 ))
flutter_ota release android --kind apk --channel staging --server-url "$SERVER_URL" \
  --build-number "$build_number" "${engine[@]}" 2>&1 | tee "$OUT/release.log"
release_id="$(sed -n 's/^Release \([0-9a-f-]\{36\}\) is registered\.$/\1/p' "$OUT/release.log" | tail -1)"
apk_rel="$(sed -n 's/^ *Store file to upload to Google Play: //p' "$OUT/release.log" | tail -1)"
[[ -n "$release_id" && -f "$APP/$apk_rel" ]] || die "release failed (see release.log)"
mkdir -p "$OUT/apk" && cp "$APP/$apk_rel" "$OUT/apk/ota_shot2-$MODE.apk"
echo "release $release_id" | tee -a "$OUT/steps.log"

log "Install and run the store build"
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" install "$OUT/apk/ota_shot2-$MODE.apk" >>"$OUT/steps.log"
launch run1_store bench
starts store

# ---------------------------------------------------------------- oracles (local Dart)
log "Expected results (v1 and v2 run locally with the toolchain Dart)"
for v in v1 v2; do
  (cd "$STUBS/cases/$v" && "$DART" pub get --offline >/dev/null 2>&1 || "$DART" pub get >/dev/null)
  (cd "$STUBS/cases/$v" && "$DART" run bin/main.dart) >"$OUT/oracle_$v.txt"
done

# ---------------------------------------------------------------- patch
if [[ "$MODE" != plain ]]; then
  log "Patch: change the app to v2 and ship it"
  set_cases v2
  flutter_ota patch android --release "$release_id" --channel staging 2>&1 | tee "$OUT/patch.log"
  grep -q 'uploaded as server patch' "$OUT/patch.log" || die "patch failed (see patch.log)"
  seq_dir="$(ls -d "$APP/.flutter_ota/releases/$release_id/patches/"*/ | sort -V | tail -1)"
  cp "$seq_dir/patch.json" "$OUT/patch.json"
  cp "$seq_dir/patch.otp" "$OUT/patch.otp"
  set_cases v1   # the project goes back to the store version for the next run

  log "Start 1 after the patch: the phone downloads and verifies it"
  launch run2_download bench
  log "Start 2 after the patch: the patch runs"
  launch run3_patched
  for extra in 1 2; do
    grep -q 'status=patched' "$OUT/run3_patched.log" && break
    log "not patched yet, one more start ($extra)"
    launch run2_download_more$extra bench
    launch run3_patched
  done
  launch run4_patched_bench bench
  starts patched
fi

# ---------------------------------------------------------------- sizes and report
log "Report"
unzip -l "$OUT/apk/ota_shot2-$MODE.apk" | awk '/lib\/arm64-v8a\/libapp.so/{print "libapp.so " $1} END{}' >"$OUT/sizes.txt"
echo "apk $(stat -c %s "$OUT/apk/ota_shot2-$MODE.apk")" >>"$OUT/sizes.txt"
[[ -f "$OUT/patch.otp" ]] && echo "patch.otp $(stat -c %s "$OUT/patch.otp")" >>"$OUT/sizes.txt"
python3 "$HERE/report_shot2.py" "$OUT" "$MODE" | tee "$OUT/report.md"
echo
echo "Results: $OUT"
echo "APK for other phones: $OUT/apk/ota_shot2-$MODE.apk (see SHOT2.md: they need a server URL they can reach)"
