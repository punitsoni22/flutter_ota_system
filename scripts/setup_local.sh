#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Kept for compatibility (CI, scripts/prepublish_check.sh, older docs): same as ./flutter-ota-system.sh setup.
# Creates .env if missing (random local secrets), builds, creates the LOCAL dev signing key once,
# starts the stack and waits for health checks. Safe to re-run: never replaces .env, data or key.
exec "$(cd "$(dirname "$0")/.." && pwd)/flutter-ota-system.sh" setup "$@"
