#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Shared helpers for ./flutter-ota-system.sh and the scripts in scripts/. Sourced, not executed.
# Bash 3.2+ (macOS default) compatible on purpose; only Linux is tested.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 2; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine (Linux) or Docker Desktop: docs/installation.md#1-prerequisites"
  docker info >/dev/null 2>&1 || die "Docker is not running, or your user cannot use it (try: docker run --rm hello-world)."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 not found (the 'docker compose' command)."
  local v major minor
  v="$(docker compose version --short 2>/dev/null || true)"; v="${v#v}"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
    if (( major < 2 || (major == 2 && minor < 20) )); then
      die "Docker Compose $v is too old; Flutter OTA System needs Compose v2.20 or newer."
    fi
  fi
}

need_env() {
  [[ -f .env ]] || die ".env not found. Run: ./flutter-ota-system.sh setup   (or: cp .env.example .env)"
  if grep -Eq '^OTA_ENV=production' .env; then
    die "OTA_ENV=production in .env. These scripts are for LOCAL development only."
  fi
  migrate_legacy_env
}

# One-time upgrade of a local install made before the project was renamed to Flutter OTA System.
# The old names appear here on purpose: they are what an existing .env and Docker volumes use.
LEGACY_ENV_PREFIX="PUNIT_"   # old prefix of the FLUTTER_OTA_* settings
LEGACY_PROJECT="punit"       # old Compose project name (volumes punit_pgdata, punit_keys, ...)
migrate_legacy_env() {
  local stamp
  grep -q "^${LEGACY_ENV_PREFIX}" .env || return 0   # nothing from before the rename
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -p .env ".env.pre-rename-${stamp}"
  sed -i.tmp "s/^${LEGACY_ENV_PREFIX}/FLUTTER_OTA_/" .env && rm -f .env.tmp
  warn "Renamed the old ${LEGACY_ENV_PREFIX}* settings in .env to FLUTTER_OTA_* (copy kept: .env.pre-rename-${stamp})."
  # This .env belongs to an old install: keep using its data by pinning the old project name if
  # its volumes exist and the new project has none yet. Moving the data: docs/operations.md.
  if ! grep -q '^COMPOSE_PROJECT_NAME=' .env && command -v docker >/dev/null 2>&1 \
      && docker volume inspect "${LEGACY_PROJECT}_pgdata" >/dev/null 2>&1 \
      && ! docker volume inspect "flutter-ota-system_pgdata" >/dev/null 2>&1; then
    printf '\n# Added after the rename: this install keeps its data in the "%s" volumes.\nCOMPOSE_PROJECT_NAME=%s\n' \
      "$LEGACY_PROJECT" "$LEGACY_PROJECT" >> .env
    warn "Existing data found in the '${LEGACY_PROJECT}' Docker volumes: .env now pins COMPOSE_PROJECT_NAME=${LEGACY_PROJECT} so it stays in use."
  fi
}

# One setting, with the same precedence as Docker Compose: the shell environment first, then
# .env, then the default. .env is never evaluated as code.
env_value() {
  local key="$1" default="${2:-}" line
  if [[ -n "${!key:-}" ]]; then printf '%s' "${!key}"; return 0; fi
  line="$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 || true)"
  if [[ -n "$line" ]]; then printf '%s' "${line#*=}"; else printf '%s' "$default"; fi
}

compose() { docker compose "$@"; }
tools()   { docker compose --profile tools run --rm tools "$@"; }

# The Compose project name in effect (.env COMPOSE_PROJECT_NAME, else "flutter-ota-system" from the file).
project_name() {
  local n
  n="$(compose config 2>/dev/null | sed -n 's/^name: *//p' | head -n1)"
  printf '%s' "${n:-flutter-ota-system}"
}

api_url() { printf 'http://localhost:%s' "$(env_value FLUTTER_OTA_API_PORT 8000)"; }
cdn_url() { printf 'http://localhost:%s' "$(env_value FLUTTER_OTA_CDN_PORT 8080)"; }

# 64 hex characters from the OS random generator (no openssl needed).
rand_hex() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }

# True if the api container of this project is running.
api_running() { [[ -n "$(compose ps -q --status running api 2>/dev/null)" ]]; }

# True if something accepts TCP connections on 127.0.0.1:<port>.
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Prints "<key_id>:<base64 point>" of the running API's signing key (the app's OTA_PUBLIC_KEY).
public_key() {
  compose exec -T api python -c '
import json, os, urllib.request
r = urllib.request.Request("http://127.0.0.1:8000/v1/admin/signing-key",
                           headers={"X-API-Key": os.environ["OTA_ADMIN_API_KEY"]})
i = json.load(urllib.request.urlopen(r, timeout=5))
print(i["key_id"] + ":" + i["uncompressed_point_base64"])' 2>/dev/null
}

# Server id of the demo application (OTA_APPLICATION_ID for the example app); empty if not seeded.
demo_app_id() {
  compose exec -T api python -c '
import json, os, urllib.request
r = urllib.request.Request("http://127.0.0.1:8000/v1/admin/apps",
                           headers={"X-API-Key": os.environ["OTA_ADMIN_API_KEY"]})
apps = json.load(urllib.request.urlopen(r, timeout=5))
print(next((a["id"] for a in apps if a["slug"] == "flutter-ota-system-demo"), ""))' 2>/dev/null
}

# Asks the user to type a word. Returns 0 only on an exact match. Works with piped input.
confirm_word() {  # prompt word
  local ans=""
  printf '%s\nType "%s" to continue: ' "$1" "$2"
  read -r ans || true
  [[ "$ans" == "$2" ]]
}
