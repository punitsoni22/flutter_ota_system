#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Creates the LOCAL DEVELOPMENT ES256 signing key ONCE inside the Docker volume "<project>_keys"
# (default flutter-ota-system_keys). Run by ./flutter-ota-system.sh setup/up/update; it never replaces an existing key.
#
# The private key never touches your working tree, so it cannot be committed by accident. The
# file is mode 600 in a mode 700 folder, owned by the API's non-root user.
# It is NOT suitable for production: it is unencrypted, has no HSM/Key Vault protection and is
# deleted by ./flutter-ota-system.sh reset and ./scripts/cleanup_local.sh. Production keys: docs/security.md.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_docker
need_env

if ! docker image inspect "$(env_value FLUTTER_OTA_API_IMAGE flutter-ota-system-api:local)" >/dev/null 2>&1; then
  say "Building the API image"
  compose build api
fi

key_path=/data/keys/ota_signing_private.pem
if compose run --rm --no-deps -T --entrypoint sh api -c "test -s $key_path"; then
  say "Dev signing key already exists in volume $(project_name)_keys (not replaced)."
else
  say "Generating LOCAL DEVELOPMENT signing key (ES256 / P-256)"
  compose run --rm --no-deps -T api python -m app.keygen | grep -v 'BACK IT UP' || true
  compose run --rm --no-deps -T --entrypoint sh api -c "test -s $key_path && chmod 600 $key_path" \
    || die "Key generation failed."
  warn "This key is for local development only. Never use it to sign production patches."
fi
