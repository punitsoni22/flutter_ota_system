#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Writes one version of the test cases to a folder:
#
#   make_version.sh <v1|v2|scenario> <dest>
#
# A scenario (scenarios/<name>/scenario.txt) starts from `base:` (v1 or v2), takes the files in
# `from_v2:` from cases/v2, then copies its own lib/ on top.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES="$(cd "$HERE/../cases" && pwd)"
name="${1:?version or scenario}"
dest="${2:?destination folder}"

rm -rf "$dest"
case "$name" in
  v1|v2) base="$name" ;;
  *)
    s="$HERE/scenarios/$name"
    [[ -f "$s/scenario.txt" ]] || { echo "unknown scenario $name" >&2; exit 64; }
    base="$(sed -n 's/^base: *//p' "$s/scenario.txt")"
    [[ "$base" == v1 || "$base" == v2 ]] || { echo "$name: base must be v1 or v2" >&2; exit 64; }
    ;;
esac
mkdir -p "$(dirname "$dest")"
cp -R "$CASES/$base" "$dest"
rm -rf "$dest/.dart_tool"
if [[ "$name" != v1 && "$name" != v2 ]]; then
  for f in $(sed -n 's/^from_v2: *//p' "$s/scenario.txt"); do
    mkdir -p "$(dirname "$dest/lib/$f")"
    cp "$CASES/v2/lib/$f" "$dest/lib/$f"
  done
  if [[ -d "$s/lib" ]]; then cp -R "$s/lib/." "$dest/lib/"; fi
fi
