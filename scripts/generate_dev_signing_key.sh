#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Creates the LOCAL DEVELOPMENT ES256 signing key inside the Docker volume "punit_keys".
#
# The private key never touches your working tree, so it cannot be committed by accident.
# It is NOT suitable for production: it is unencrypted, has no HSM/Key Vault protection and is
# deleted by ./scripts/cleanup_local.sh. Production keys: see docs/security.md.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_docker
need_env

if ! docker image inspect punit-api:local >/dev/null 2>&1; then
  say "Building the API image"
  compose build api
fi

key_path=/data/keys/ota_signing_private.pem
if compose run --rm --no-deps -T --entrypoint sh api -c "test -s $key_path"; then
  say "Dev signing key already exists in volume punit_keys (not replaced)."
else
  say "Generating LOCAL DEVELOPMENT signing key (ES256 / P-256)"
  compose run --rm --no-deps -T api python -m app.keygen | grep -v 'BACK IT UP' || true
  compose run --rm --no-deps -T --entrypoint sh api -c "test -s $key_path" \
    || die "Key generation failed."
  warn "This key is for local development only. Never use it to sign production patches."
fi
