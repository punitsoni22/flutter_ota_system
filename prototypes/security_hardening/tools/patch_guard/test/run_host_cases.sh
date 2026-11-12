#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Runs patch_guard on the fixture cases that need a host package list (--host-packages):
# fixtures/host_cases.tsv. Complements scripts/run_guard_tests.sh (which runs fixtures/cases.tsv
# without a host list, plus the dart2bytecode validator as ground truth).
#
#   LAB=~/.cache/flutter-ota-lab ./tools/patch_guard/test/run_host_cases.sh <out-dir>
# Optional: GUARD_AOT=<snapshot> (default $LAB/work/tools/patch_guard.aot), WORK=<scratch dir>.
# The finding rules must match the expected rules EXACTLY. Exit 1 if any case does not match.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
OUT=$(realpath -m "$1")
SDK="$LAB/flutter"
DART="$SDK/bin/cache/dart-sdk/bin/dart"
AOT="$SDK/bin/cache/dart-sdk/bin/dartaotruntime"
DART_SRC="$LAB/engine/engine/src/flutter/third_party/dart"
FIX="$HERE/fixtures"
WORK=${WORK:-"$LAB/work/guard_host_fixtures"}
GUARD_SRC="$HERE/bin/patch_guard.dart"
GUARD_AOT=${GUARD_AOT:-"$LAB/work/tools/patch_guard.aot"}
mkdir -p "$OUT" "$(dirname "$GUARD_AOT")"
if [[ ! -s $GUARD_AOT || $GUARD_SRC -nt $GUARD_AOT ]]; then
  nice -n 10 "$DART" compile aot-snapshot --packages="$DART_SRC/.dart_tool/package_config.json" -o "$GUARD_AOT" "$GUARD_SRC" >/dev/null
fi

# Work on a copy so pub get never writes into the repository.
rm -rf "$WORK" && mkdir -p "$WORK" && cp -r "$FIX/packages" "$WORK/"
TSV="$OUT/guard_host_results.tsv"
printf 'case\thost_list\texpected\tguard\texpected_rules\tguard_rules\tresult\n' > "$TSV"
fail=0
while IFS=$'\t' read -r name mods host expected rules; do
  [[ -z $name || $name == \#* ]] && continue
  pkg=${mods%%,*}
  dir="$WORK/packages/$pkg"
  (cd "$dir" && nice -n 10 "$DART" pub get --offline >/dev/null 2>&1) || { echo "pub get failed for $name"; fail=1; continue; }
  hostargs=()
  [[ $host != "-" ]] && hostargs=(--host-packages "$FIX/hosts/$host")
  nice -n 10 "$AOT" "$GUARD_AOT" --root "$WORK/packages" --package-config "$dir/.dart_tool/package_config.json" \
    --module-packages "$mods" ${hostargs[@]+"${hostargs[@]}"} --sdk "$SDK/bin/cache/dart-sdk" \
    --json "$OUT/$name.json" > "$OUT/$name.guard.log" 2>&1
  rc=$?
  verdict=$([[ $rc == 0 ]] && echo accept || { [[ $rc == 4 ]] && echo reject || echo "error($rc)"; })
  got=$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(",".join(sorted({f["rule"] for f in r["findings"]})) or "-")' "$OUT/$name.json" 2>/dev/null || echo "?")
  want=$(tr ',' '\n' <<< "$rules" | sort | paste -sd, -)
  ok=PASS
  [[ $verdict == "$expected" && $got == "$want" ]] || { ok=FAIL; fail=1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host" "$expected" "$verdict" "$want" "$got" "$ok" >> "$TSV"
done < "$FIX/host_cases.tsv"
column -t -s $'\t' "$TSV"
exit $fail
