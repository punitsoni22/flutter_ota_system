#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds every Phase 3 device-test artifact against one baseline and records the build outcome.
#   LAB=~/.cache/flutter-ota-lab ./scripts/build_device_artifacts.sh <baseline> <out-dir>
# Writes <out-dir>/*.otp, <out-dir>/build.tsv (name, exit code, expectation, result) and the
# security corpus in <out-dir>/corpus/otp.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
BASE=$(realpath "$1"); O=$(realpath -m "$2")
P2="$HERE/../real_app_compatibility/patches"
KEYS="$LAB/keys/p3"
rm -rf "$O" && mkdir -p "$O"
TSV="$O/build.tsv"; printf 'artifact\texit\texpected\tresult\tdetail\n' > "$TSV"
mk() {  # <name> <expected-exit> <module-dir> <sequence> [VAR=value ...]
  local name=$1 want=$2 dir=$3 seq=$4; shift 4
  env "$@" "$HERE/scripts/make_patch.sh" "$BASE" "$dir" "$O/$name.otp" "$seq" > "$O/$name.log" 2>&1
  local rc=$? res=PASS
  [[ $rc == "$want" ]] || res=FAIL
  [[ $want == 4 && -e $LAB/work/modules/${NAME_FOR_CHECK:-x}/module.bc ]] && res=FAIL
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$rc" "$want" "$res" "$(grep -m1 -E 'Imported through|Reason|patch_id' "$O/$name.log" | tr '\t' ' ' | cut -c1-120)" >> "$TSV"
}
mk v1 0 "$P2/patch_v1" 1
mk v2 0 "$P2/patch_v2" 2
for v in ok:10 throw_init:11 abort_in_entry:12 abort_when_logged_in:13 abort_after_frame:14 throw_when_logged_in:15; do
  mk "crash_${v%%:*}" 0 "$HERE/patches/crash_p3" "${v##*:}" NAME="crash_${v%%:*}" ENTRY="lib/entry_${v%%:*}.dart"
done
NAME_FOR_CHECK=patch_ffi mk ffi_guarded 4 "$HERE/patches/patch_ffi" 20
NAME_FOR_CHECK=patch_dynamic mk dynamic_guarded 4 "$HERE/patches/patch_dynamic" 21
mk ffi_unguarded_signed 0 "$HERE/patches/patch_ffi" 22 NAME=patch_ffi_noguard NOGUARD=1
mk v3_for_kill 0 "$P2/patch_v1" 3 NAME=v3_for_kill
mk v4_after_kill 0 "$P2/patch_v1" 4 NAME=v4_after_kill
# Install-mode negatives derived from the v2 build (sequence 30+, i.e. newer than v2).
M="$LAB/work/modules/patch_v2"; MP=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["module"])' "$M.rename.json")
signv2() {  # <name> <key-pem> <key-id> <seq> [override...]
  local name=$1 pem=$2 kid=$3 seq=$4; shift 4
  python3 -I "$HERE/tools/sign_patch.py" sign --key "$KEYS/$pem.pem" --key-id "$kid" --baseline "$BASE" --module "$M/module.bc" \
    --rename-report "$M.rename.json" --module-config "$M/$MP/.dart_tool/package_config.json" --sequence "$seq" --out "$O/$name.otp" \
    "${@/#/--override=}" > "$O/$name.log" 2>&1
  printf '%s\t%s\t0\t%s\t-\n' "$name" "$?" "$([[ $? == 0 ]] && echo PASS || echo FAIL)" >> "$TSV"
}
signv2 neg_wrong_key p3-rogue p3-dev-1 30
signv2 neg_untrusted_key p3-rogue p3-rogue 31
signv2 neg_wrong_baseline p3-dev-1 p3-dev-1 32 'baseline_libapp_sha256="'"$(printf 'c%.0s' {1..64})"'"'
signv2 neg_wrong_engine p3-dev-1 p3-dev-1 33 'runtime.engine="00000000"'
signv2 neg_expired p3-dev-1 p3-dev-1 34 'expires_at="2026-01-01T00:00:00Z"'
python3 -I - "$O" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
v2 = d.joinpath("v2.otp").read_bytes()
t = bytearray(v2); t[-200] ^= 1
d.joinpath("neg_tampered_module.otp").write_bytes(bytes(t))
d.joinpath("neg_partial_download.otp").write_bytes(v2[: len(v2) * 6 // 10])
PY
# Malformed module (truncated), validly signed, newer sequence: install mode.
python3 -I - "$M/module.bc" "$O/truncated.bc" <<'PY'
import sys; b = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(b[: len(b) // 2])
PY
python3 -I "$HERE/tools/sign_patch.py" sign --key "$KEYS/p3-dev-1.pem" --key-id p3-dev-1 --baseline "$BASE" --module "$O/truncated.bc" \
  --rename-report "$M.rename.json" --module-config "$M/$MP/.dart_tool/package_config.json" --sequence 50 --out "$O/malformed_signed.otp" > /dev/null
# Signed revocation list revoking v2.
V2ID=$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["patch_id"])' "$O/v2.log")
python3 -I "$HERE/tools/sign_patch.py" revoke --key "$KEYS/p3-dev-1.pem" --key-id p3-dev-1 \
  --release "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["baseline_id"])' "$BASE/baseline.json")" \
  --sequence 1 --patch-id "$V2ID" --out "$O/revoke_v2.otp" > /dev/null
echo "$V2ID" > "$O/v2.id"
"$HERE/scripts/build_corpus.sh" "$BASE" patch_v1 "$O/corpus" > /dev/null
column -t -s $'\t' "$TSV"
echo "corpus: $(ls "$O/corpus/otp" | wc -l) files"
