#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Regression check for the REFERENCE bytecode verifier (bc_verify) on the committed fixtures.
#
#   DART=<pinned dart> DART_PACKAGES=<dart-src>/.dart_tool/package_config.json \
#     prototypes/security_hardening/tools/bc_verify/test/run_fixtures.sh
#
# Defaults point to the lab layout (~/.cache/flutter-ota-lab). The package config must come from
# the pinned Dart source tree (it provides package:dart2bytecode).
#
# Checks:
#   1. every fixture's SHA-256 equals fixtures.json "fixture_sha256";
#   2. every valid/*.bc is accepted ("OK");
#   3. every malformed/*.bc is rejected ("REJECT"), except the documented harmless accept
#      17_unknown_host_class (known limitation L4: the module is structurally valid; the unknown
#      host class is resolved later by the VM);
#   4. B25 and B27 are rejected for the expected reason.
# Exit code 0 when all checks pass, 1 otherwise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="${FLUTTER_OTA_LAB:-$HOME/.cache/flutter-ota-lab}"
DART="${DART:-$LAB/flutter/bin/cache/dart-sdk/bin/dart}"
DART_PACKAGES="${DART_PACKAGES:-$LAB/engine/engine/src/flutter/third_party/dart/.dart_tool/package_config.json}"
FIX="$HERE/fixtures"

for f in "$DART" "$DART_PACKAGES"; do
  [ -e "$f" ] || { echo "missing: $f (set DART / DART_PACKAGES)" >&2; exit 2; }
done

fail=0

# 1. SHA-256 against fixtures.json.
while read -r rel want; do
  got="$(sha256sum "$FIX/$rel" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then echo "FAIL sha256 $rel"; fail=1; fi
done < <(python3 -I -c '
import json, sys
for k, v in json.load(open(sys.argv[1]))["files"].items():
    print(k, v["fixture_sha256"])
' "$FIX/fixtures.json")

count="$(find "$FIX/valid" "$FIX/malformed" -name '*.bc' | wc -l)"
[ "$count" -eq 16 ] || { echo "FAIL expected 16 fixtures, found $count"; fail=1; }

# 2-4. Verifier results (bc_verify exits 1 when any module is rejected; we check each line).
out="$(cd "$HERE" && "$DART" --packages="$DART_PACKAGES" bin/bc_verify.dart \
  fixtures/valid/*.bc fixtures/malformed/*.bc || true)"
echo "$out"

for f in "$FIX"/valid/*.bc; do
  rel="fixtures/valid/$(basename "$f")"
  grep -q "^OK $rel " <<<"$out" || { echo "FAIL expected OK: $rel"; fail=1; }
done
for f in "$FIX"/malformed/*.bc; do
  name="$(basename "$f" .bc)"
  rel="fixtures/malformed/$name.bc"
  if [ "$name" = "17_unknown_host_class" ]; then
    grep -q "^OK $rel " <<<"$out" || { echo "FAIL expected documented accept (L4): $rel"; fail=1; }
  else
    grep -q "^REJECT $rel " <<<"$out" || { echo "FAIL expected REJECT: $rel"; fail=1; }
  fi
done
grep -q "^REJECT fixtures/malformed/25_codes_opcode_1.bc .*reserved or VM-internal opcode" <<<"$out" \
  || { echo "FAIL B25 not rejected as reserved opcode"; fail=1; }
grep -q "^REJECT fixtures/malformed/27_codes_opcode_3.bc .*argument count" <<<"$out" \
  || { echo "FAIL B27 not rejected for argument count"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "bc_verify fixtures: PASS (6 OK, 9 REJECT, 1 documented accept)"; fi
exit "$fail"
