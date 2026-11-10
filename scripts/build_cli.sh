#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Builds the `ota` CLI as a wheel and sdist in cli/dist/ (local use only; nothing is uploaded).
#   ./scripts/build_cli.sh
# Needs Python 3.10+ with venv. Build tools go into a throwaway virtualenv.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Copy the CLI and the licence files into a clean folder, so the package carries them.
mkdir "$WORK/src"
cp "$ROOT"/cli/pyproject.toml "$ROOT"/cli/README.md "$ROOT"/cli/*.py "$WORK/src/"
cp "$ROOT"/LICENSE "$ROOT"/NOTICE "$ROOT"/THIRD_PARTY_NOTICES.md "$WORK/src/"

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet --upgrade pip build
rm -rf "$ROOT/cli/dist"
"$WORK/venv/bin/python" -m build --outdir "$ROOT/cli/dist" "$WORK/src"
ls -l "$ROOT/cli/dist"
