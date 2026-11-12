#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds a SIGNED Phase 3 patch (container v2):
#   pkg_rename prepare -> patch_guard (rejects FFI, dynamic calls, ...) -> dart2bytecode ->
#   sign_patch.py (ES256 over the canonical manifest).
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/make_patch.sh <baseline> <module-dir> <out.otp> <sequence>
# Env: KEY=p3-dev-1 (key id under $LAB/keys/p3), NAME, ENTRY (variants), NOGUARD=1 (build a module
# the guard would refuse, ONLY to test the device-side protection), EXTRA="--override k=v ...".
# Exit 4 = rejected by patch_guard before any bytecode was generated; 3 = refused by pkg_rename.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
# Canonical build directory (no user name; same path on every machine -> reproducible bytecode).
export MODULES_DIR=${MODULES_DIR:-/tmp/flutter-ota-build}
[[ $# == 4 ]] || { echo "usage: make_patch.sh <baseline> <module-dir> <out.otp> <sequence>" >&2; exit 2; }
BASE=$(realpath "$1"); MOD=$(realpath "$2"); OTP=$(realpath -m "$3"); SEQ=$4
KEY=${KEY:-p3-dev-1}
NAME=${NAME:-$(basename "$MOD")}
export NAME
GUARD_ARG="$HERE/tools/patch_guard/bin/patch_guard.dart"
[[ -n ${NOGUARD:-} ]] && GUARD_ARG=""
GUARD="$GUARD_ARG" "$HERE/../real_app_compatibility/scripts/make_module.sh" "$BASE" "$MOD" "$MODULES_DIR/$NAME.v1.otp" >/dev/null
OUT="$MODULES_DIR/$NAME"
MODPKG=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["module"])' "$OUT.rename.json")
# shellcheck disable=SC2086
python3 -I "$HERE/tools/sign_patch.py" sign --key "$LAB/keys/p3/$KEY.pem" --key-id "$KEY" --baseline "$BASE" \
  --module "$OUT/module.bc" --rename-report "$OUT.rename.json" \
  --module-config "$OUT/$MODPKG/.dart_tool/package_config.json" --sequence "$SEQ" --out "$OTP" ${EXTRA:-}
