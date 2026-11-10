#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# One-time local setup: .env, image build, LOCAL dev signing key, start the stack.
# Safe to re-run: it never replaces an existing key or .env.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_docker
if [[ ! -f .env ]]; then
  cp .env.example .env
  say "Created .env from .env.example (local-only fake values)."
fi
need_env

say "Building the API image"
compose build api

"$ROOT/scripts/generate_dev_signing_key.sh"

say "Starting postgres, api, cdn (waiting for health checks)"
compose up -d --wait postgres api cdn
compose ps

api_port="$(env_value PUNIT_API_PORT 8000)"
say "Ready."
echo "  API:    http://localhost:${api_port}   (OpenAPI docs: /docs)"
echo "  Admin:  http://localhost:${api_port}/admin   (key: OTA_ADMIN_API_KEY in .env)"
echo "  CDN:    http://localhost:$(env_value PUNIT_CDN_PORT 8080)/health"
echo
echo "Next: ./scripts/seed_demo.sh && ./scripts/publish_test_patch.sh && ./scripts/verify_demo.sh"
