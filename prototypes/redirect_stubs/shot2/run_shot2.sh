#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
# Shot 2: the redirect patch engine on a real Android phone. See SHOT2.md.
#
#   APP_ID=<server app uuid> FLUTTER_OTA_ADMIN_KEY=<admin key> ./run_shot2.sh <mode>
#
# Modes (each makes its own store build, installs it and measures it on the phone):
#   stock            plain `flutter build apk`: no OTA, no dynamic interface (true baseline)
#   plain            the feature engine (OTA on, full interface, no checks); no patch
#   redirect         every function has a check; patch v1 -> v2
#   redirect-fast    tiny leaf functions have no check; patch v1 -> v2, then the extra stages:
#                    patch chain + rollback, two bad patches (crash protection), patch size ladder
#   redirect-narrow  as redirect-fast, with the EXPERIMENTAL app-only interface; patch v1 -> v2
#   all              every mode above in turn, then one combined report (about 90 minutes)
#
# Optional environment:
#   WORK         work folder (default: <repo>/.local/ota_shot2, git-ignored). It must be inside
#                this checkout: the CLI needs the app and packages/ota_client (a path dependency)
#                in one workspace folder below the home folder.
#   CLI_DART     Dart used once to activate this checkout's CLI (default: dart on PATH). Use a
#                plain SDK path if `dart` is a wrapper that fails in scripts (for example snap).
#   SERVER_URL   server as the phone and this machine see it (default: http://localhost:8000; the
#                phone reaches it through `adb reverse`)
#   ANDROID_SERIAL  phone to use when several are connected
#   STARTS       cold starts measured per state (default: 5)
#   SKIP_CLI_ACTIVATE=1  use the flutter_ota already on PATH instead of this checkout's CLI

set -euo pipefail

MODE="${1:-redirect}"
MODES=(stock plain redirect-narrow redirect redirect-fast)
case "$MODE" in stock|plain|redirect|redirect-fast|redirect-narrow|all) ;; *) echo "unknown mode $MODE" >&2; exit 64 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUBS="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$STUBS/../.." && pwd)"
WORK="${WORK:-$REPO/.local/ota_shot2}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK/" in
  "$(cd "$REPO" && pwd -P)/"*) ;;
  *) echo "WORK=$WORK must be inside this checkout ($REPO): the CLI needs the test app and" \
       "packages/ota_client in one workspace folder. Leave WORK unset to use $REPO/.local/ota_shot2." >&2
     exit 64 ;;
esac
export WORK

# ---------------------------------------------------------------- all modes, one combined report
if [[ "$MODE" == all ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  failed=()
  for m in "${MODES[@]}"; do
    echo; echo "################ $m"
    "$HERE/run_shot2.sh" "$m" || failed+=("$m")
    export SKIP_CLI_ACTIVATE=1   # activated once, by the first mode
  done
  python3 "$HERE/compare_shot2.py" "$WORK/results" | tee "$WORK/results/combined-$STAMP.md"
  echo
  echo "Combined report: $WORK/results/combined-$STAMP.md"
  ((${#failed[@]} == 0)) || echo "Modes that stopped early (their folders say why): ${failed[*]}"
  exit 0
fi

APP="$WORK/app"
VERSIONS="$WORK/versions"
CLI_DART="${CLI_DART:-dart}"
SERVER_URL="${SERVER_URL:-http://localhost:8000}"
export FLUTTER_OTA_SERVER_URL="$SERVER_URL"
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
for t in adb python3 unzip perl; do command -v "$t" >/dev/null || die "$t is not installed"; done

# A stage that may fail without stopping the run: its failure is recorded in failures.txt.
run_stage() {
  local name="$1"; shift
  set +e
  ( set -e; "$@" )
  local rc=$?
  set -e
  if ((rc != 0)); then
    echo "$name" >>"$OUT/failures.txt"
    log "stage '$name' FAILED (exit $rc); continuing with the next stage"
  fi
  set_cases v1
}

# ---------------------------------------------------------------- CLI from this checkout
if [[ "${SKIP_CLI_ACTIVATE:-0}" != 1 ]]; then
  log "Activating the flutter_ota CLI of this checkout"
  command -v "$CLI_DART" >/dev/null || die "$CLI_DART not found (needed once to activate the CLI; set CLI_DART)"
  "$CLI_DART" pub global activate --source path "$REPO/packages/flutter_ota_cli" >>"$OUT/steps.log" 2>&1 ||
    die "activating the CLI with $CLI_DART failed (see steps.log). If dart is a snap or other wrapper," \
        "set CLI_DART to the dart binary of a Flutter or Dart SDK folder."
fi
export PATH="$PATH:${PUB_CACHE:-$HOME/.pub-cache}/bin"
command -v flutter_ota >/dev/null || die "flutter_ota is not on PATH"

# ---------------------------------------------------------------- versions of the test cases
version_dir() { # v1 | v2 | scenario -> folder with that version (made once per run)
  local d="$VERSIONS/$1"
  [[ -d "$d" ]] || "$HERE/make_version.sh" "$1" "$d"
  echo "$d"
}
set_cases() { # the test cases of a version in the app
  local d; d="$(version_dir "$1")"
  rm -rf "$APP/lib/src" "$APP/lib/cases.dart"
  cp -R "$d/lib/src" "$APP/lib/src"
  cp "$d/lib/cases.dart" "$APP/lib/cases.dart"
}
rm -rf "$VERSIONS"

toolchain_flutter() {
  local tc
  tc="$(sed -n 's/^toolchain: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$APP/flutter_ota.lock" | head -1)"
  local f="${FLUTTER_OTA_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/flutter_ota}/toolchains/$tc/flutter/bin/flutter"
  [[ -x "$f" ]] || die "toolchain Flutter not found at $f"
  echo "$f"
}

# ---------------------------------------------------------------- app (created once)
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
set_cases v1
(flutter_ota keys init --server-url "$SERVER_URL") >>"$OUT/steps.log" 2>&1 || die "keys init failed (see $OUT/steps.log)"

# ---------------------------------------------------------------- expected results (local Dart)
log "Expected results (v1, v2 and v3 run locally with the toolchain Dart)"
for v in v1 v2 v3; do
  d="$(version_dir "$v")"
  (cd "$d" && "$DART" pub get --offline >/dev/null 2>&1 || "$DART" pub get >/dev/null)
  (cd "$d" && "$DART" run bin/main.dart) >"$OUT/oracle_$v.txt"
done

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
  echo "serial: $("${ADB[@]}" get-serialno | tr -d '\r')"
} | tee "$OUT/phone.txt"

save_logs() { # name: the app's log lines, plain and with timestamps
  "${ADB[@]}" logcat -d -v raw -s flutter:I >"$OUT/$1.log"
  "${ADB[@]}" logcat -d -v epoch -s flutter:I >"$OUT/$1.epoch.log"
}

launch() { # name [bench]: one cold start; waits for the cases (or the bench), then saves the logs
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
  if [[ "$until" != bench ]]; then
    # Past the stable period, so crash protection never counts a test stop as a failed start.
    sleep 15
    "${ADB[@]}" shell dumpsys meminfo "$PKG" >"$OUT/$name.meminfo.txt" 2>&1 || true
  fi
  save_logs "$name"
  grep '\[shot2\] start' "$OUT/$name.log" | tail -1 | tee -a "$OUT/steps.log"
}

launch_crash() { # name: a start that may end the process; records "survived" or "died"
  local name="$1" end
  "${ADB[@]}" shell am force-stop "$PKG"
  "${ADB[@]}" logcat -c
  "${ADB[@]}" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 4
  end=$((SECONDS + 60))
  local outcome=timeout
  while (( SECONDS < end )); do
    "${ADB[@]}" logcat -d -v raw -s flutter:I >"$OUT/$name.log"
    if grep -q '\[shot2\] cases_done' "$OUT/$name.log"; then outcome=survived; break; fi
    if ! "${ADB[@]}" shell pidof "$PKG" >/dev/null 2>&1; then outcome=died; break; fi
    sleep 2
  done
  [[ "$outcome" == survived ]] && sleep 15
  save_logs "$name"
  echo "$name $outcome" | tee -a "$OUT/crash_starts.txt" "$OUT/steps.log"
}

starts() { # label: STARTS cold starts, start lines collected in <label>_starts.txt
  : >"$OUT/$1_starts.txt"
  for i in $(seq 1 "$STARTS"); do
    launch "$1_start$i" >/dev/null
    grep '\[shot2\] start' "$OUT/$1_start$i.log" | tail -1 >>"$OUT/$1_starts.txt"
  done
}

patch_id_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"]["patch_id"])' "$1"; }

ship_patch() { # label version: build, sign, upload and publish a patch; keeps <label>.json/.otp/.log
  set_cases "$2"
  flutter_ota patch android --release "$release_id" --channel staging 2>&1 | tee "$OUT/$1.log"
  grep -q 'uploaded as server patch' "$OUT/$1.log" || die "$1: patch failed (see $1.log)"
  local seq_dir
  seq_dir="$(ls -d "$APP/.flutter_ota/releases/$release_id/patches/"*/ | sort -V | tail -1)"
  cp "$seq_dir/patch.json" "$OUT/$1.json"
  cp "$seq_dir/patch.otp" "$OUT/$1.otp"
  set_cases v1
}

until_running() { # label patch_id: starts the app until it runs that patch (at most 3 rounds)
  for i in 1 2 3; do
    launch "$1_try$i" bench
    if grep -q "patch=$2" "$OUT/$1_try$i.log"; then
      cp "$OUT/$1_try$i.log" "$OUT/$1.log"
      return 0
    fi
  done
  die "$1: the phone did not run patch $2 after 3 starts"
}

# ---------------------------------------------------------------- store build
build_number=$(( $(date +%s) / 60 ))
mkdir -p "$OUT/apk"
APK="$OUT/apk/ota_shot2-$MODE.apk"
if [[ "$MODE" == stock ]]; then
  log "Stock build: flutter build apk, no OTA (no release, no interface, no patch)"
  "$FLUTTER" pub get >>"$OUT/steps.log" 2>&1
  "$FLUTTER" build apk --release --target-platform android-arm64 --build-number "$build_number" 2>&1 | tee "$OUT/release.log"
  cp "$APP/build/app/outputs/flutter-apk/app-release.apk" "$APK"
  release_id=none
else
  log "Store release ($MODE)"
  case "$MODE" in
    plain) engine=(--engine feature) ;;
    redirect) engine=(--engine redirect) ;;
    redirect-fast) engine=(--engine redirect --skip-leaves) ;;
    redirect-narrow) engine=(--engine redirect --skip-leaves --interface-scope app) ;;
  esac
  flutter_ota release android --kind apk --channel staging --server-url "$SERVER_URL" \
    --build-number "$build_number" "${engine[@]}" 2>&1 | tee "$OUT/release.log"
  release_id="$(sed -n 's/^Release \([0-9a-f-]\{36\}\) is registered\.$/\1/p' "$OUT/release.log" | tail -1)"
  apk_rel="$(sed -n 's/^ *Store file to upload to Google Play: //p' "$OUT/release.log" | tail -1)"
  [[ -n "$release_id" && -f "$APP/$apk_rel" ]] || die "release failed (see release.log)"
  cp "$APP/$apk_rel" "$APK"
  cp "$APP/.flutter_ota/releases/$release_id/dynamic_interface.yaml" "$OUT/dynamic_interface.yaml" 2>/dev/null || true
fi
echo "release $release_id" | tee -a "$OUT/steps.log"

log "Install and run the store build"
"${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" install "$APK" >>"$OUT/steps.log"
launch run1_store bench
starts store

# ---------------------------------------------------------------- stages
stage_patch() { # patch v1 -> v2, download, run, measure
  log "Patch 1: the app changes to v2"
  ship_patch patch v2
  cp "$OUT/patch.json" "$OUT/patch1.json"
  log "Start 1 after the patch: the phone downloads and verifies it"
  launch run2_download bench
  log "Start 2 after the patch: the patch runs"
  launch run3_patched
  for extra in 1 2; do
    grep -q 'status=patched' "$OUT/run3_patched.log" && break
    log "not patched yet, one more start ($extra)"
    launch "run2_download_more$extra" bench
    launch run3_patched
  done
  grep -q 'status=patched' "$OUT/run3_patched.log" || die "the patch never ran"
  launch run4_patched_bench bench
  starts patched
}

stage_chain() { # A: patch 2 on top (v3 = v2 + one line), then roll patch 2 back
  log "A. Patch chain: patch 2 (v3 = v2 plus one line)"
  ship_patch patch2_v3 v3
  until_running chain_v3 "$(patch_id_of "$OUT/patch2_v3.json")"
  log "A. Roll patch 2 back on the server; the phone must return to patch 1"
  flutter_ota rollback --release "$release_id" --yes 2>&1 | tee "$OUT/rollback.log"
  until_running chain_rollback "$(patch_id_of "$OUT/patch.json")"
}

stage_bad_patches() { # F: crash protection with redirect patches
  log "F1. Bad patch: an uncaught Dart error from patched code at start-up"
  ship_patch patch3_f1 f1_dart_error
  local f1; f1="$(patch_id_of "$OUT/patch3_f1.json")"
  until_running f1_running "$f1"
  launch f1_again1
  launch f1_again2
  log "F2. Bad patch: patched code ends the process at start-up"
  ship_patch patch4_f2 f2_process_crash
  launch f2_download bench
  : >"$OUT/crash_starts.txt"
  for i in 1 2 3 4 5; do
    launch_crash "f2_start$i"
    if grep -q "f2_start$i survived" "$OUT/crash_starts.txt" && ! grep -q "patch=$(patch_id_of "$OUT/patch4_f2.json")" "$OUT/f2_start$i.log"; then
      break
    fi
  done
}

stage_ladder() { # B: patch size ladder (built and signed locally, not uploaded)
  log "B. Patch size ladder (dry runs)"
  : >"$OUT/ladder.txt"
  for s in l1_one_line l1_bodies l2_signatures_additions l3_structure; do
    set_cases "$s"
    local t0=$SECONDS
    flutter_ota patch android --release "$release_id" --dry-run >"$OUT/ladder_$s.log" 2>&1 || die "ladder $s failed (see ladder_$s.log)"
    local seq_dir
    seq_dir="$(ls -d "$APP/.flutter_ota/releases/$release_id/patches/"*/ | sort -V | tail -1)"
    cp "$seq_dir/patch.json" "$OUT/ladder_$s.json"
    echo "$s $((SECONDS - t0)) $(stat -c %s "$seq_dir/patch.otp" 2>/dev/null || echo 0)" >>"$OUT/ladder.txt"
  done
}

case "$MODE" in
  redirect|redirect-narrow)
    run_stage patch stage_patch ;;
  redirect-fast)
    run_stage patch stage_patch
    if [[ -f "$OUT/run4_patched_bench.log" ]]; then
      run_stage chain stage_chain
      run_stage bad_patches stage_bad_patches
    fi
    run_stage ladder stage_ladder ;;
esac
set_cases v1

# ---------------------------------------------------------------- sizes and report
log "Report"
{
  unzip -l "$APK" | awk '/lib\/arm64-v8a\/libapp.so/{print "libapp.so " $1}'
  echo "apk $(stat -c %s "$APK")"
  for f in "$OUT"/patch*.otp; do [[ -f "$f" ]] && echo "$(basename "$f") $(stat -c %s "$f")"; done
  [[ -f "$OUT/dynamic_interface.yaml" ]] && echo "interface_entries $(grep -c '^  - library' "$OUT/dynamic_interface.yaml")"
  true
} >"$OUT/sizes.txt"
python3 "$HERE/report_shot2.py" "$OUT" "$MODE" | tee "$OUT/report.md"
echo
echo "Results: $OUT"
echo "APK for other phones: $APK (see SHOT2.md: they need a server URL they can reach)"
[[ ! -f "$OUT/failures.txt" ]] || { echo "Stages that failed: $(tr '\n' ' ' <"$OUT/failures.txt")"; exit 1; }
