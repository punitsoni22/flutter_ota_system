#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the device security corpus (verify-only requests, never activated):
#   control (valid), cryptographic/compatibility negatives, and the malformed-bytecode corpus
#   (tools/corpus.py) with every malformed module VALIDLY SIGNED by a trusted key.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/build_corpus.sh <baseline> <patch_v1-module-name> <out-dir>
# Needs a module built earlier by make_patch.sh (its module.bc, rename report and package config).
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
BASE=$(realpath "$1"); NAME=$2; OUT=$(realpath -m "$3")
M="$LAB/work/modules/$NAME"
MODPKG=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["module"])' "$M.rename.json")
KEYS="$LAB/keys/p3"
rm -rf "$OUT" && mkdir -p "$OUT/otp"
sign() {  # <module.bc> <out.otp> <seq> [key] [extra...]
  local mod=$1 out=$2 seq=$3 key=${4:-p3-dev-1}; shift 4 || shift $#
  python3 -I "$HERE/tools/sign_patch.py" sign --key "$KEYS/$key.pem" --key-id "$key" --baseline "$BASE" \
    --module "$mod" --rename-report "$M.rename.json" --module-config "$M/$MODPKG/.dart_tool/package_config.json" \
    --sequence "$seq" --out "$out" "$@" >/dev/null
}
# Controls and cryptographic/compatibility negatives (A_*).
sign "$M/module.bc" "$OUT/otp/A00_control_valid.otp" 1
sign "$M/module.bc" "$OUT/otp/A01_untrusted_key.otp" 1 p3-rogue
sign "$M/module.bc" "$OUT/otp/A02_wrong_app.otp" 1 p3-dev-1 --override 'app_id="00000000-0000-4000-8000-000000000000"'
sign "$M/module.bc" "$OUT/otp/A03_wrong_baseline.otp" 1 p3-dev-1 --override 'baseline_libapp_sha256="'"$(printf 'c%.0s' {1..64})"'"'
sign "$M/module.bc" "$OUT/otp/A04_wrong_engine.otp" 1 p3-dev-1 --override 'runtime.engine="00000000"'
sign "$M/module.bc" "$OUT/otp/A05_expired.otp" 1 p3-dev-1 --override 'expires_at="2026-01-01T00:00:00Z"'
sign "$M/module.bc" "$OUT/otp/A06_second_trusted_key.otp" 1 p3-dev-2
# Trusted key id, but signed with another private key.
python3 -I "$HERE/tools/sign_patch.py" sign --key "$KEYS/p3-rogue.pem" --key-id p3-dev-1 --baseline "$BASE" \
  --module "$M/module.bc" --rename-report "$M.rename.json" --module-config "$M/$MODPKG/.dart_tool/package_config.json" \
  --sequence 1 --out "$OUT/otp/A10_trusted_id_wrong_key.otp" >/dev/null
python3 -I - "$OUT/otp" "$KEYS" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
v = d.joinpath("A00_control_valid.otp").read_bytes()
t = bytearray(v); t[-100] ^= 0x01                  # bytecode modified after signing
d.joinpath("A07_tampered_module.otp").write_bytes(bytes(t))
m = bytearray(v); i = v.index(b'"sequence":1'); m[i + 11] = ord("9")   # manifest modified after signing
d.joinpath("A08_tampered_manifest.otp").write_bytes(bytes(m))
d.joinpath("A09_truncated_download.otp").write_bytes(v[: len(v) * 6 // 10])
PY
# Malformed bytecode, validly signed (B_*).
python3 -I "$HERE/tools/corpus.py" "$M/module.bc" "$OUT/bc" --random 20 >/dev/null
for f in "$OUT"/bc/*.bc; do
  n=$(basename "$f" .bc)
  sign "$f" "$OUT/otp/B${n}.otp" 1
done
# The FFI module built without the guard, validly signed (C_*).
FFI="$LAB/work/modules/patch_ffi_noguard"
if [[ -s $FFI/module.bc ]]; then
  MP=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["module"])' "$FFI.rename.json")
  python3 -I "$HERE/tools/sign_patch.py" sign --key "$KEYS/p3-dev-1.pem" --key-id p3-dev-1 --baseline "$BASE" \
    --module "$FFI/module.bc" --rename-report "$FFI.rename.json" --module-config "$FFI/$MP/.dart_tool/package_config.json" \
    --sequence 1 --out "$OUT/otp/C01_signed_ffi_module.otp" >/dev/null
fi
ls "$OUT/otp" | wc -l
