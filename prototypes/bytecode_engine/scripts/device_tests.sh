#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Runs the Phase 1 scenarios on a connected device or emulator and records evidence
# (logcat lines, screenshots, APK hashes) in $RESULTS.
#
#   ./scripts/device_tests.sh <baseline-dir> <valid.otp> <variants-dir> <results-dir>
set -uo pipefail
BASE=$(realpath "$1"); VALID=$(realpath "$2"); VAR=$(realpath "$3"); RESULTS=$(realpath -m "$4")
PKG=io.github.punitsoni22.bytecode_proto
INBOX=/sdcard/Android/data/$PKG/files/inbox
mkdir -p "$RESULTS"
SUMMARY="$RESULTS/summary.txt"; : > "$SUMMARY"

apk_state() {  # installed APK hash + install time: must never change after the first install
  local path; path=$(adb shell pm path $PKG | sed -n 's/^package://p' | tr -d '\r')
  echo "$(adb shell sha256sum "$path" | cut -d' ' -f1) $(adb shell dumpsys package $PKG | grep -m1 lastUpdateTime | tr -d '\r ')"
}
start_app() {  # cold start; prints the prototype's log lines for this start
  adb shell am force-stop $PKG; adb logcat -c
  adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep "${WAIT:-12}"
  adb logcat -d | grep -F '[ota-proto]' | sed 's/^.*\[ota-proto\]/[ota-proto]/'
}
push() { adb shell mkdir -p $INBOX; adb push "$1" "$INBOX/patch.otp" >/dev/null; }
check() {  # name, expected greeting substring, log output
  local name=$1 expect=$2 log=$3 result
  if grep -q "greeting=\"$expect" <<< "$log"; then result=PASS; else result=FAIL; fi
  adb exec-out screencap -p > "$RESULTS/$name.png"
  printf '%-34s %s\n' "$name" "$result" | tee -a "$SUMMARY"
  printf '%s\n' "$log" > "$RESULTS/$name.log"
}

V1='Original implementation: Hello from version 1'
V2='Patched implementation: Hello from version 2'

adb uninstall $PKG >/dev/null 2>&1
adb install "$BASE/app-release.apk" >/dev/null
INSTALLED=$(apk_state); echo "installed APK: $INSTALLED" | tee -a "$SUMMARY"

check 01_no_patch_baseline "$V1" "$(start_app)"
push "$VALID"; check 02_valid_patch_applied "$V2" "$(start_app)"
check 02b_cold_restart_still_patched "$V2" "$(start_app)"
for i in 1 2 3; do push "$VALID"; L=$(start_app); done
check 10_repeated_application "$V2" "$L"
adb shell mkdir -p $INBOX; adb shell touch $INBOX/ROLLBACK
check 08_rollback_to_baseline "$V1" "$(start_app)"
check 09_restart_after_rollback "$V1" "$(start_app)"
for v in corrupted_module wrong_format wrong_runtime wrong_app wrong_baseline missing_module garbage; do
  push "$VAR/$v.otp"
  L=$(start_app)
  check "neg_$v" "$V1" "$L"
  grep -q "REJECTED" <<< "$L" || echo "  (no REJECTED line for $v)" | tee -a "$SUMMARY"
done
# 11: after the invalid artifacts the app still starts normally (no crash loop).
PID=$(adb shell pidof $PKG | tr -d '\r')
check 11_no_crash_loop_after_invalid "$V1" "$(start_app)"
echo "process alive after invalid artifacts: ${PID:-no}" | tee -a "$SUMMARY"
# Valid patch again after all the negatives: the store was not corrupted.
push "$VALID"; check 10b_valid_after_negatives "$V2" "$(start_app)"

FINAL=$(apk_state)
echo "APK unchanged across all tests: $([[ $FINAL == "$INSTALLED" ]] && echo yes || echo NO) ($FINAL)" | tee -a "$SUMMARY"
cat "$SUMMARY"
