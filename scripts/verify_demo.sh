#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# End-to-end verification of the local stack. Exits non-zero if any check fails.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need_docker; need_env
command -v curl >/dev/null 2>&1 || die "curl not found"

fail=0
host_check() {  # name url
  if curl -fsS -o /dev/null --max-time 5 "$2"; then echo "[PASS] $1"; else echo "[FAIL] $1 ($2)"; fail=1; fi
}
api="http://localhost:$(env_value FLUTTER_OTA_API_PORT 8000)"
cdn="http://localhost:$(env_value FLUTTER_OTA_CDN_PORT 8080)"
host_check "API reachable from host" "$api/health/ready"
host_check "CDN reachable from host" "$cdn/health"
if curl -fsS -o /dev/null --max-time 5 "$cdn/cdn/releases/x" 2>/dev/null; then
  echo "[FAIL] CDN must not serve private release files"; fail=1
else
  echo "[PASS] CDN does not serve private release files"
fi

tools verify || fail=1
exit "$fail"
