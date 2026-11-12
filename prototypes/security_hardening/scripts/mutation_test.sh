#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Mutation testing (Part 10): each security check is disabled in a TEMPORARY COPY of the code,
# the matching tests are run, and they must FAIL. The repository is never modified.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/mutation_test.sh <baseline> <out-dir>
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
BASE=$(realpath "$1"); OUT=$(realpath -m "$2"); mkdir -p "$OUT"
DART="$LAB/flutter/bin/cache/dart-sdk/bin/dart"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TSV="$OUT/mutations.tsv"; printf 'mutant\ttarget\tdisabled check\ttests\tresult\n' > "$TSV"

mutate() {  # <file> <old> <new> -> 0 if replaced exactly once
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if s.count(sys.argv[2]) != 1: sys.exit(f"pattern found {s.count(sys.argv[2])} times")
p.write_text(s.replace(sys.argv[2], sys.argv[3]))
PY
}

# --- patch_security verifier -----------------------------------------------------------------
V=src/verifier.dart
cp -r "$HERE/packages/patch_security" "$TMP/ps_clean"
(cd "$TMP/ps_clean" && "$DART" pub get --offline >/dev/null 2>&1)
while IFS='|' read -r id file old new what; do
  [[ -z $id || $id == \#* ]] && continue
  rm -rf "$TMP/ps" && cp -r "$TMP/ps_clean" "$TMP/ps"
  if ! mutate "$TMP/ps/lib/$file" "$old" "$new" 2>"$OUT/$id.err"; then
    printf '%s\tpatch_security\t%s\t-\tERROR (pattern)\n' "$id" "$what" >> "$TSV"; continue
  fi
  (cd "$TMP/ps" && "$DART" test test/verifier_test.dart > "$OUT/$id.log" 2>&1)
  rc=$?
  failed=$(grep -oE '\-[0-9]+: Some tests failed' "$OUT/$id.log" | head -1)
  printf '%s\tpatch_security\t%s\t%s\t%s\n' "$id" "$what" "${failed:-all passed}" "$([[ $rc != 0 ]] && echo KILLED || echo SURVIVED)" >> "$TSV"
done <<'MUT'
m01|src/verifier.dart|!keys.verify(m.keyId, signedMessage(manifestDomain, parts.manifestBytes), signature)|false|ES256 signature check
m02|src/verifier.dart|if (sha256.convert(parts.module).toString() != m.moduleSha256)|if (false)|module SHA-256 check
m03|src/verifier.dart|if (parts.module.length != m.moduleSize)|if (false)|module size check
m04|src/verifier.dart|if (m.appId != host.appId)|if (false)|application id check
m05|src/verifier.dart|if (m.releaseId != host.releaseId)|if (false)|store release check
m06|src/verifier.dart|if (m.baselineLibappSha256 != host.baselineLibappSha256)|if (false)|libapp.so baseline check
m07|src/verifier.dart|if (!sameActive && m.sequence <= state.highestSequence)|if (false)|replay (sequence) check
m08|src/verifier.dart|if (exp != null && !now.toUtc().isBefore(DateTime.parse(exp)))|if (false)|expiry check
m09|src/verifier.dart|if (state.revokedKeyIds.contains(m.keyId))|if (false)|revoked key check
m10|src/verifier.dart|if (state.blacklist.contains(m.patchId))|if (false)|blacklist check
m11|src/verifier.dart|if (m.runtime[e.key] != e.value)|if (false)|runtime compatibility check
m12|src/verifier.dart|if (host.hostOwnedPackages.contains(p['name']))|if (false)|host-owned package check
m13|src/canonical.dart|final again = canonicalJson(value);|final again = bytes;|canonical form check
m14|src/manifest.dart|if (!_top.contains(k)) bad('unknown field "$k"');|{}|unknown-field check
m15|src/container.dart|if (12 + mLen + 4 > file.length) throw PatchRejected('truncated', 'manifest extends past the end of the file');|{}|manifest bounds check
MUT

# --- patch_guard --------------------------------------------------------------------------------
G="$HERE/tools/patch_guard/bin/patch_guard.dart"
while IFS='|' read -r id old new what; do
  [[ -z $id || $id == \#* ]] && continue
  cp "$G" "$TMP/guard_$id.dart"
  if ! mutate "$TMP/guard_$id.dart" "$old" "$new" 2>"$OUT/$id.err"; then
    printf '%s\tpatch_guard\t%s\t-\tERROR (pattern)\n' "$id" "$what" >> "$TSV"; continue
  fi
  # The guard runs from the Dart SDK checkout's package config; copy beside the original for imports.
  cp "$TMP/guard_$id.dart" "$HERE/tools/patch_guard/bin/.mutant_$id.dart"
  GUARD_SRC="$HERE/tools/patch_guard/bin/.mutant_$id.dart" GUARD_AOT="$TMP/guard_$id.aot" \
    "$HERE/scripts/run_guard_tests.sh" "$BASE" "$OUT/$id" > "$OUT/$id.log" 2>&1
  rc=$?
  rm -f "$HERE/tools/patch_guard/bin/.mutant_$id.dart"
  failed=$(grep -c 'FAIL$' "$OUT/$id/guard_results.tsv" 2>/dev/null || echo 0)
  printf '%s\tpatch_guard\t%s\t%s fixture cases failed\t%s\n' "$id" "$what" "$failed" "$([[ $rc != 0 ]] && echo KILLED || echo SURVIVED)" >> "$TSV"
done <<'MUT'
g01|        if (lib == 'dart:ffi') {|        if (false) {|FFI import (graph) check
g02|    if (lib != null && lib.uri.toString() == 'dart:ffi') {|    if (false) {|FFI element (resolved AST) check
g03|    if (target != null && isDyn(target.staticType) && !objectMember(node.methodName.name)) {|    if (false) {|dynamic method call check
g04|uris.add((c.uri.stringValue!, line, true));|{}|conditional-import configurations
g05|    if (node.name.lexeme == 'noSuchMethod')|    if (false)|noSuchMethod check
MUT
column -t -s $'\t' "$TSV"
grep -qE 'SURVIVED|ERROR' "$TSV" && exit 1 || exit 0
