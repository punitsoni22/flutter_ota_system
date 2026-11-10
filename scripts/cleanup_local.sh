#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Stops the local stack and DELETES its volumes: database, patch files AND the dev signing key.
#   ./scripts/cleanup_local.sh          asks first
#   ./scripts/cleanup_local.sh --yes    no prompt (CI)
#   ./scripts/cleanup_local.sh --keep-data   stop containers only
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need_docker

case "${1:-}" in
  --keep-data) compose --profile tools down --remove-orphans; exit 0 ;;
  --yes) ;;
  *)
    read -r -p "Delete the local Punit database, patch files and dev signing key? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    ;;
esac
compose --profile tools down -v --remove-orphans
say "Local stack and volumes removed. Your .env was kept."
