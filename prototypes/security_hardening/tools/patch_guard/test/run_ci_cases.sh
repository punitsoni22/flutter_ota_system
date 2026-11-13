#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Runs patch_guard on every fixture case WITHOUT the lab (used by GitHub Actions CI):
#   fixtures/cases.tsv       same checks as scripts/run_guard_tests.sh (verdict, expected rules
#                            present), but without the dart2bytecode validator ground truth, which
#                            needs the lab SDK sources and a host baseline (lab-only);
#   fixtures/host_cases.tsv  same checks as test/run_host_cases.sh (verdict, rules exactly equal).
# The guard is compiled with the published analyzer pinned in ../pubspec.yaml instead of the
# analyzer vendored in the Dart SDK source tree.
#
#   DART_SDK=<flutter>/bin/cache/dart-sdk ./tools/patch_guard/test/run_ci_cases.sh <out-dir>
# DART_SDK defaults to $FLUTTER_ROOT/bin/cache/dart-sdk (FLUTTER_ROOT: from `flutter` on PATH).
# Use the pinned Flutter (3.47.9, Dart 3.13.7). Exit 1 if any case does not match.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(realpath -m "$1")
if [[ -z ${DART_SDK:-} && -z ${FLUTTER_ROOT:-} ]] && command -v flutter >/dev/null; then
  FLUTTER_ROOT=$(cd -- "$(dirname -- "$(readlink -f "$(command -v flutter)")")/.." && pwd)
fi
SDK=${DART_SDK:-"${FLUTTER_ROOT:?set DART_SDK or FLUTTER_ROOT}/bin/cache/dart-sdk"}
DART="$SDK/bin/dart"
AOT="$SDK/bin/dartaotruntime"
FIX="$HERE/fixtures"
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
"$DART" --version

# Compile the guard once against the pinned analyzer.
(cd "$HERE" && "$DART" pub get >/dev/null) || { echo "pub get failed for patch_guard"; exit 1; }
GUARD_AOT="$WORK/patch_guard.aot"
"$DART" compile aot-snapshot --packages="$HERE/.dart_tool/package_config.json" \
  -o "$GUARD_AOT" "$HERE/bin/patch_guard.dart" >/dev/null || { echo "guard compile failed"; exit 1; }

# Work on a copy so pub get never writes into the repository.
cp -r "$FIX/packages" "$WORK/"
fail=0
total=0

# run_case <name> <module packages> <host file or -> <expected> <expected rules> <exact 0|1>
run_case() {
  local name=$1 mods=$2 host=$3 expected=$4 rules=$5 exact=$6
  local pkg=${mods%%,*} dir rc verdict got want ok
  dir="$WORK/packages/$pkg"
  total=$((total + 1))
  (cd "$dir" && "$DART" pub get --offline >/dev/null 2>&1) || { echo "pub get failed for $name"; fail=1; return; }
  local hostargs=()
  [[ $host != "-" ]] && hostargs=(--host-packages "$FIX/hosts/$host")
  "$AOT" "$GUARD_AOT" --root "$WORK/packages" --package-config "$dir/.dart_tool/package_config.json" \
    --module-packages "$mods" ${hostargs[@]+"${hostargs[@]}"} --sdk "$SDK" \
    --json "$OUT/$name.json" > "$OUT/$name.guard.log" 2>&1
  rc=$?
  if [[ $rc == 0 ]]; then verdict=accept; elif [[ $rc == 4 ]]; then verdict=reject; else verdict="error($rc)"; fi
  got=$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(",".join(sorted({f["rule"] for f in r["findings"]})) or "-")' "$OUT/$name.json" 2>/dev/null || echo "?")
  want=$(tr ',' '\n' <<< "$rules" | sort | paste -sd, -)
  ok=PASS
  [[ $verdict == "$expected" ]] || ok=FAIL
  if [[ $exact == 1 ]]; then
    [[ $got == "$want" ]] || ok=FAIL
  elif [[ $rules != "-" ]]; then
    for r in ${rules//,/ }; do [[ ",$got," == *",$r,"* ]] || ok=FAIL; done
  fi
  [[ $ok == FAIL ]] && fail=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host" "$expected" "$verdict" "$want" "$got" "$ok" >> "$TSV"
}

TSV="$OUT/guard_ci_results.tsv"
printf 'case\thost_list\texpected\tguard\texpected_rules\tguard_rules\tresult\n' > "$TSV"
while IFS=$'\t' read -r name mods expected rules; do
  [[ -z $name || $name == \#* ]] && continue
  run_case "$name" "$mods" - "$expected" "$rules" 0
done < "$FIX/cases.tsv"
while IFS=$'\t' read -r name mods host expected rules; do
  [[ -z $name || $name == \#* ]] && continue
  run_case "$name" "$mods" "$host" "$expected" "$rules" 1
done < "$FIX/host_cases.tsv"
column -t -s $'\t' "$TSV"
passed=$(grep -c $'\tPASS$' "$TSV")
echo "patch_guard fixture cases: $passed/$total passed"
exit $fail
