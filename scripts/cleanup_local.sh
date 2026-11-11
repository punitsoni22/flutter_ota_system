#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Stops the local stack and DELETES its volumes: database, patch files AND the dev signing key.
#   ./scripts/cleanup_local.sh              asks first (y/N)
#   ./scripts/cleanup_local.sh --yes        no prompt (CI and scripts/prepublish_check.sh only)
#   ./scripts/cleanup_local.sh --keep-data  remove containers only (= ./flutter-ota-system.sh down)
# Interactive users: prefer ./flutter-ota-system.sh reset (asks you to type the project name).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need_docker

case "${1:-}" in
  --keep-data) compose --profile tools down --remove-orphans; exit 0 ;;
  --yes) ;;
  *)
    read -r -p "Delete the local Flutter OTA System database, patch files and dev signing key of project '$(project_name)'? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    ;;
esac
compose --profile tools down -v --remove-orphans
say "Local stack '$(project_name)' and its volumes removed. Your .env and backups/ were kept."
