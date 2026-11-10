#!/usr/bin/env bash
# Shared helpers for the Punit local scripts. Sourced, not executed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 2; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine or Docker Desktop."
  docker info >/dev/null 2>&1 || die "Docker is not running, or your user cannot use it (try: docker run --rm hello-world)."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 not found (the 'docker compose' command)."
}

need_env() {
  [[ -f .env ]] || die ".env not found. Run: cp .env.example .env"
  if grep -Eq '^OTA_ENV=production' .env; then
    die "OTA_ENV=production in .env. These scripts are for LOCAL development only."
  fi
}

# Read one value from .env (no eval of the file).
env_value() {
  local key="$1" default="${2:-}" line
  line="$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 || true)"
  if [[ -n "$line" ]]; then printf '%s' "${line#*=}"; else printf '%s' "$default"; fi
}

compose() { docker compose "$@"; }
tools()   { docker compose --profile tools run --rm tools "$@"; }
