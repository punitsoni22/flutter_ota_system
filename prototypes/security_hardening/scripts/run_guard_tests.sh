#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Runs patch_guard on every fixture case (tools/patch_guard/fixtures/cases.tsv) and, as ground
# truth, the upstream dart2bytecode validator against a recorded baseline.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/run_guard_tests.sh <baseline-dir> <out-dir>
# Writes <out-dir>/guard_results.tsv and one JSON report + log per case. Exit 1 if any case
# does not match its expected verdict.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
BASE=$(realpath "$1"); OUT=$(realpath -m "$2")
SDK="$LAB/flutter"
DART="$SDK/bin/cache/dart-sdk/bin/dart"
AOT="$SDK/bin/cache/dart-sdk/bin/dartaotruntime"
DART_SRC="$LAB/engine/engine/src/flutter/third_party/dart"
PLATFORM="$SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill"
TOOLS="$LAB/work/tools"
FIX="$HERE/tools/patch_guard/fixtures"
WORK="$LAB/work/guard_fixtures"
mkdir -p "$OUT" "$TOOLS"
snapshot() {
  if [[ ! -s $2 || $1 -nt $2 ]]; then
    nice -n 10 "$DART" compile aot-snapshot --packages="$DART_SRC/.dart_tool/package_config.json" -o "$2" "$1" >/dev/null
  fi
}
GUARD_SRC=${GUARD_SRC:-"$HERE/tools/patch_guard/bin/patch_guard.dart"}
GUARD_AOT=${GUARD_AOT:-"$TOOLS/patch_guard.aot"}
snapshot "$GUARD_SRC" "$GUARD_AOT"
snapshot "$DART_SRC/pkg/dart2bytecode/bin/dart2bytecode.dart" "$TOOLS/dart2bytecode.aot"

# Work on a copy so pub get never writes into the repository.
rm -rf "$WORK" && mkdir -p "$WORK" && cp -r "$FIX/packages" "$WORK/"
TSV="$OUT/guard_results.tsv"
printf 'case\texpected\tguard\tguard_rules\tvalidator\tvalidator_first_error\tresult\n' > "$TSV"
fail=0
while IFS=$'\t' read -r name mods expected rules; do
  [[ -z $name || $name == \#* ]] && continue
  dir="$WORK/packages/case_$name"
  (cd "$dir" && "$DART" pub get --offline >/dev/null 2>&1) || { echo "pub get failed for $name"; fail=1; continue; }
  cfg="$dir/.dart_tool/package_config.json"
  "$AOT" "$GUARD_AOT" --root "$WORK/packages" --package-config "$cfg" --module-packages "$mods" \
    --sdk "$SDK/bin/cache/dart-sdk" --json "$OUT/$name.json" > "$OUT/$name.guard.log" 2>&1
  rc=$?
  verdict=$([[ $rc == 0 ]] && echo accept || { [[ $rc == 4 ]] && echo reject || echo "error($rc)"; })
  got=$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(",".join(sorted({f["rule"] for f in r["findings"]})) or "-")' "$OUT/$name.json" 2>/dev/null || echo "?")
  # Ground truth: the upstream compiler + validator, default flags.
  "$AOT" "$TOOLS/dart2bytecode.aot" --target flutter --platform "$PLATFORM" --import-dill "$BASE/link.dill" \
    --validate "$BASE/dynamic_interface.yaml" --packages "$cfg" -o "$OUT/$name.bc" "$dir/lib/entry.dart" > "$OUT/$name.validator.log" 2>&1
  vrc=$?
  vfirst=$(grep -m1 -oE "Error: .{0,90}" "$OUT/$name.validator.log" | tr '\t' ' ' || true)
  validator=$([[ $vrc == 0 ]] && echo compiles || echo rejects)
  rm -f "$OUT/$name.bc"
  ok=PASS
  [[ $verdict == "$expected" ]] || ok=FAIL
  if [[ $rules != "-" ]]; then
    for r in ${rules//,/ }; do [[ ",$got," == *",$r,"* ]] || ok=FAIL; done
  fi
  [[ $ok == FAIL ]] && fail=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$expected" "$verdict" "$got" "$validator" "${vfirst:--}" "$ok" >> "$TSV"
done < "$FIX/cases.tsv"
column -t -s $'\t' "$TSV"
exit $fail
