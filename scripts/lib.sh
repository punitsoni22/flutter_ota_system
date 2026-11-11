#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Shared helpers for ./punit.sh and the scripts in scripts/. Sourced, not executed.
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
      die "Docker Compose $v is too old; Punit needs Compose v2.20 or newer."
    fi
  fi
}

need_env() {
  [[ -f .env ]] || die ".env not found. Run: ./punit.sh setup   (or: cp .env.example .env)"
  if grep -Eq '^OTA_ENV=production' .env; then
    die "OTA_ENV=production in .env. These scripts are for LOCAL development only."
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

# The Compose project name in effect (.env COMPOSE_PROJECT_NAME, else "punit" from the file).
project_name() {
  local n
  n="$(compose config 2>/dev/null | sed -n 's/^name: *//p' | head -n1)"
  printf '%s' "${n:-punit}"
}

api_url() { printf 'http://localhost:%s' "$(env_value PUNIT_API_PORT 8000)"; }
cdn_url() { printf 'http://localhost:%s' "$(env_value PUNIT_CDN_PORT 8080)"; }

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

# Asks the user to type a word. Returns 0 only on an exact match. Works with piped input.
confirm_word() {  # prompt word
  local ans=""
  printf '%s\nType "%s" to continue: ' "$1" "$2"
  read -r ans || true
  [[ "$ans" == "$2" ]]
}
