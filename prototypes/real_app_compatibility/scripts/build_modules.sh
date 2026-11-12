#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds every Phase 2 patch, probe and crash variant against one baseline. A failure to compile
# is a RESULT (recorded), not a script error.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/build_modules.sh <baseline-dir> <out-dir>
# Writes <out-dir>/<name>.otp, <out-dir>/<name>.log and <out-dir>/modules.tsv
#   (name, status OK|REFUSED|COMPILE_FAILED, module bytes, otp bytes, compile ms).
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
BASE=$(realpath "$1"); OUT=$(realpath -m "$2")
mkdir -p "$OUT"
TSV="$OUT/modules.tsv"; printf 'name\tstatus\tmodule_bytes\totp_bytes\tcompile_ms\n' > "$TSV"

build() {  # <name> <module-dir> [ENTRY] [NUMBER]
  local name=$1 dir=$2 rc line
  NAME=$name ENTRY=${3:-lib/entry.dart} NUMBER=${4:-} "$HERE/scripts/make_module.sh" "$BASE" "$dir" "$OUT/$name.otp" > "$OUT/$name.log" 2>&1
  rc=$?
  if [[ $rc == 0 ]]; then
    line=$(tail -1 "$OUT/$name.log")
    python3 -I -c 'import json,sys; m=json.loads(sys.argv[1]); print("\t".join([sys.argv[2],"OK",str(m["module_size"]),str(m["otp_size"]),str(m["compile_ms"])]))' "$line" "$name" >> "$TSV"
  elif [[ $rc == 3 ]]; then
    printf '%s\tREFUSED\t-\t-\t-\n' "$name" >> "$TSV"
  else
    printf '%s\tCOMPILE_FAILED\t-\t-\t-\n' "$name" >> "$TSV"
  fi
  tail -1 "$TSV"
}

for m in patch_v1 patch_v2 patch_v3 patch_v3_stale patch_v4 patch_v5; do build "$m" "$HERE/patches/$m"; done
for v in ok:20 throw:21 abort_before_frame:22 abort_after_frame:23 build_error:24; do
  build "crash_${v%%:*}" "$HERE/patches/crash" "lib/entry_${v%%:*}.dart" "${v##*:}"
done
for p in "$HERE"/probes/*/; do build "$(basename "$p")" "$p"; done
