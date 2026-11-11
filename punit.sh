#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Punit local stack: one command for setup and day-to-day operation (LOCAL DEVELOPMENT ONLY).
# Run ./punit.sh help for the commands. Tested on Linux only; see docs/installation.md.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/scripts/lib.sh"

CLI_VENV="$ROOT/.venv-cli"
SERVICES=(postgres api cdn)

usage() {
  cat <<'EOF'
Punit local stack (development / evaluation only)

Usage: ./punit.sh <command> [options]

Setup and lifecycle
  setup              Check requirements, create .env (random local secrets), build the image,
                     create the LOCAL dev signing key once, start and wait for health checks.
                     Safe to re-run: never overwrites .env, the database or the key.
  up | start         Start the stack (builds the image if missing) and wait until healthy
  stop               Stop the containers (keeps containers, data and key)
  down               Remove the containers and network (keeps data and key in volumes)
  restart            Restart all services and wait until healthy
  status             Containers, health, URLs, volumes and the app's OTA_PUBLIC_KEY
  logs [service...]  Follow logs (services: postgres, api, cdn)
  update             Back up, rebuild the API image from this checkout, recreate, wait.
                     (Run `git pull` yourself first. Migrations run when the API starts.)

Data
  backup [dir]       Database dump + patch files + signing key + .env copy into
                     backups/<project>-<time>/ (or [dir]). Contains secrets: keep it private.
  restore <dir>      Replace the database, files and key with a backup (asks to confirm)
  psql [args]        Open psql in the database container (e.g. psql -c "select 1")
  reset              DELETE the database, patch files and signing key (asks to confirm)

Demo and tools
  demo               Seed punit-demo, publish a signed test patch, run the end-to-end checks
  verify             Run the end-to-end checks only (scripts/verify_demo.sh)
  cli                Build the `ota` CLI wheel and install it into .venv-cli/
  ota <args>         Run the installed CLI against THIS stack (sets OTA_API_URL/OTA_API_KEY)
  help               This text
EOF
}

# ---- setup helpers ----------------------------------------------------------------------------

check_files() {
  local f missing=0
  for f in docker-compose.yml .env.example backend/Dockerfile backend/requirements.txt \
           docker/nginx-cdn.conf scripts/demo/punit_demo.py scripts/generate_dev_signing_key.sh; do
    [[ -f "$f" ]] || { warn "missing file: $f"; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || die "Required files are missing. Is this a complete clone of the repository?"
}

# Creates .env from .env.example with random local secrets. Never touches an existing .env.
ensure_env() {
  if [[ -f .env ]]; then
    ok ".env exists (not changed)"
    if grep -Eq '^(OTA_ADMIN_API_KEY|OTA_DEVICE_JWT_SECRET|OTA_ROLLOUT_HMAC_SECRET)=.*not-a-secret' .env; then
      warn ".env still uses the fake example secrets. Fine on this computer; never on a server."
    fi
    return 0
  fi
  local project keep_pg=0 tmp line key var
  # A database volume that outlived its .env still has the old password inside.
  project="$(project_name)"
  if docker volume inspect "${project}_pgdata" >/dev/null 2>&1; then
    keep_pg=1
    warn "Database volume ${project}_pgdata already exists: keeping the example POSTGRES_PASSWORD."
    warn "If that database used another password, restore your old .env or run ./punit.sh reset."
  fi
  # Settings you export before the first setup are written into the new .env, e.g.
  #   PUNIT_API_PORT=18000 PUNIT_CDN_PORT=18080 ./punit.sh setup
  if [[ -n "${PUNIT_CDN_PORT:-}" && -z "${OTA_CDN_BASE_URL:-}" ]]; then
    OTA_CDN_BASE_URL="http://localhost:${PUNIT_CDN_PORT}/cdn"
  fi
  tmp="$(mktemp "$ROOT/.env.tmp.XXXXXX")"
  chmod 600 "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    key="${line#\#}"; key="${key%%=*}"
    case "$key" in
      OTA_ADMIN_API_KEY|OTA_DEVICE_JWT_SECRET|OTA_ROLLOUT_HMAC_SECRET)
        printf '%s=local-%s\n' "$key" "$(rand_hex)" ;;
      POSTGRES_PASSWORD)
        if [[ "$keep_pg" -eq 1 ]]; then printf '%s\n' "$line"; else printf '%s=local-%s\n' "$key" "$(rand_hex)"; fi ;;
      COMPOSE_PROJECT_NAME|COMPOSE_FILE|PUNIT_API_IMAGE|PUNIT_API_PORT|PUNIT_CDN_PORT|PUNIT_POSTGRES_PORT|PUNIT_BIND_ADDRESS|OTA_CDN_BASE_URL)
        var="${!key:-}"
        if [[ -n "$var" ]]; then printf '%s=%s\n' "$key" "$var"; else printf '%s\n' "$line"; fi ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < .env.example > "$tmp"
  mv "$tmp" .env
  ok "Created .env from .env.example with random LOCAL secrets (mode 600). Not for servers."
}

# Fails early if the host ports are taken by something other than this stack.
check_ports() {
  api_running && return 0
  local name port busy=0
  for name in PUNIT_API_PORT:8000 PUNIT_CDN_PORT:8080; do
    port="$(env_value "${name%%:*}" "${name#*:}")"
    if port_in_use "$port"; then
      warn "Port $port (${name%%:*}) is already in use on this computer."
      busy=1
    fi
  done
  [[ "$busy" -eq 0 ]] || die "Free the port(s) or choose others in .env (PUNIT_API_PORT, PUNIT_CDN_PORT, OTA_CDN_BASE_URL), then re-run."
}

image_present() { docker image inspect "$(env_value PUNIT_API_IMAGE punit-api:local)" >/dev/null 2>&1; }

start_stack() {
  say "Starting ${SERVICES[*]} (waiting for health checks, up to 3 minutes)"
  if ! compose up -d --wait --wait-timeout 180 "${SERVICES[@]}"; then
    compose ps
    die "The stack did not become healthy. See: ./punit.sh logs api   and docs/troubleshooting.md"
  fi
}

probe() {  # label url
  if curl -fsS --max-time 5 -o /dev/null "$2"; then ok "$1"; else warn "not reachable: $2"; return 1; fi
}

check_health() {
  local api cdn failed=0
  api="$(api_url)"; cdn="$(cdn_url)"
  if command -v curl >/dev/null 2>&1; then
    probe "API ready      $api/health/ready" "$api/health/ready" || failed=1
    probe "Admin page     $api/admin" "$api/admin" || failed=1
    probe "File server    $cdn/health" "$cdn/health" || failed=1
  else
    warn "curl not found: skipped the host-side health checks"
  fi
  return "$failed"
}

print_info() {
  local api cdn key
  api="$(api_url)"; cdn="$(cdn_url)"
  key="$(public_key || true)"
  cat <<EOF

  API:        $api            (OpenAPI docs: $api/docs)
  Admin page: $api/admin      (key: OTA_ADMIN_API_KEY in .env)
  Files:      $cdn/cdn/patches/<sha256>
  Project:    $(project_name)   (volumes $(project_name)_pgdata, _artifacts, _keys)
  App key:    OTA_PUBLIC_KEY=${key:-<not available: is the API running?>}
              (LOCAL DEVELOPMENT KEY - never use it for production apps)
EOF
}

# ---- commands ---------------------------------------------------------------------------------

cmd_setup() {
  say "Checking requirements"
  need_docker
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), Compose $(docker compose version --short)"
  command -v curl >/dev/null 2>&1 || warn "curl not found: install it for the health and demo checks"
  check_files
  ensure_env
  need_env
  compose config -q || die "docker compose config failed: check .env"
  check_ports

  say "Building the API image $(env_value PUNIT_API_IMAGE punit-api:local) (first time: a few minutes)"
  compose build api

  "$ROOT/scripts/generate_dev_signing_key.sh"
  start_stack
  say "Checking from the host"
  check_health || die "Health checks failed. See ./punit.sh logs api"
  print_info
  cat <<'EOF'

Next steps
  ./punit.sh demo      seed punit-demo, publish a signed test patch, verify everything
  ./punit.sh cli       install the `ota` CLI, then e.g. ./punit.sh ota app list
  ./punit.sh status    URLs, health and the key for the example app
  Example app on a phone/emulator: docs/installation.md (step 8)
EOF
}

cmd_up() {
  need_docker; need_env
  image_present || { say "Building the API image"; compose build api; }
  check_ports
  "$ROOT/scripts/generate_dev_signing_key.sh"
  start_stack
  check_health || true
  print_info
}

cmd_stop()    { need_docker; need_env; compose --profile tools stop; ok "Stopped. Data and key are kept. Start again with ./punit.sh up"; }
cmd_down()    { need_docker; need_env; compose --profile tools down --remove-orphans; ok "Containers removed. Data and key are kept in volumes. Start again with ./punit.sh up"; }

cmd_restart() {
  need_docker; need_env
  say "Restarting ${SERVICES[*]}"
  compose restart "${SERVICES[@]}"
  start_stack
  check_health || true
}

cmd_status() {
  need_docker; need_env
  compose ps -a
  echo
  if api_running; then check_health || true; print_info; else warn "The API is not running. Start it with ./punit.sh up"; fi
  echo
  docker volume ls --filter "name=^$(project_name)_" --format '  volume {{.Name}}'
}

cmd_logs() { need_docker; need_env; compose logs -f --tail=100 "$@"; }

cmd_update() {
  need_docker; need_env
  if [[ "${1:-}" != "--no-backup" ]]; then
    if api_running; then cmd_backup; else warn "Stack not running: no backup taken before the update"; fi
  fi
  say "Rebuilding the API image from this checkout"
  compose build api
  "$ROOT/scripts/generate_dev_signing_key.sh"
  start_stack
  check_health || true
  ok "Updated. Database migrations ran when the API started (see ./punit.sh logs api)."
}

cmd_backup() {
  need_docker; need_env
  local project stamp dir user db
  project="$(project_name)"; stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${1:-$ROOT/backups/$project-$stamp}"
  user="$(env_value POSTGRES_USER punit)"; db="$(env_value POSTGRES_DB punit)"
  [[ -e "$dir" ]] && die "$dir already exists"
  ( umask 077; mkdir -p "$dir" )
  say "Backing up project $project into $dir"
  compose up -d --wait postgres >/dev/null
  ( umask 077
    compose exec -T postgres pg_dump -U "$user" -d "$db" --format=custom > "$dir/db.dump"
    # A one-off container (no ports, no dependencies) reads the volumes, running or not.
    compose run --rm --no-deps -T --entrypoint tar api -C /data -czf - artifacts keys > "$dir/files.tgz"
    cp .env "$dir/env"
    ( cd "$dir" && { sha256sum db.dump files.tgz 2>/dev/null || shasum -a 256 db.dump files.tgz; } > SHA256SUMS )
  )
  [[ -s "$dir/db.dump" && -s "$dir/files.tgz" ]] || die "Backup incomplete in $dir"
  ok "Backup written: $dir ($(du -sh "$dir" | cut -f1))"
  warn "It contains the signing key and .env secrets. Keep it private; copy it off this computer."
}

cmd_restore() {
  need_docker; need_env
  local dir="${1:-}" user db
  [[ -n "$dir" ]] || die "Usage: ./punit.sh restore <backup dir>"
  [[ -s "$dir/db.dump" && -s "$dir/files.tgz" ]] || die "$dir has no db.dump/files.tgz"
  if [[ -f "$dir/SHA256SUMS" ]]; then
    ( cd "$dir" && { sha256sum -c --quiet SHA256SUMS 2>/dev/null || shasum -a 256 -c SHA256SUMS >/dev/null; } ) \
      || die "Checksum mismatch in $dir: the backup is damaged"
    ok "Backup checksums verified"
  fi
  user="$(env_value POSTGRES_USER punit)"; db="$(env_value POSTGRES_DB punit)"
  confirm_word "This REPLACES the database, patch files and signing key of project $(project_name) with $dir." restore \
    || { echo "Aborted."; exit 1; }

  say "Stopping api and cdn"
  compose up -d --wait postgres >/dev/null
  compose stop api cdn
  say "Restoring the database"
  compose exec -T postgres dropdb -U "$user" --if-exists "$db"
  compose exec -T postgres createdb -U "$user" -O "$user" "$db"
  compose exec -T postgres pg_restore -U "$user" -d "$db" --no-owner --exit-on-error < "$dir/db.dump"
  say "Restoring patch files and the signing key"
  compose run --rm --no-deps -T --entrypoint sh api -c \
    'find /data/artifacts /data/keys -mindepth 1 -delete && tar -C /data -xzf -' < "$dir/files.tgz"
  start_stack
  check_health || true
  ok "Restored from $dir"
  if [[ -f "$dir/env" ]] && ! cmp -s "$dir/env" .env; then
    warn "Your current .env differs from the one in the backup ($dir/env). The database password"
    warn "is unaffected by a restore, but OTA_ROLLOUT_HMAC_SECRET decides rollout groups: copy the"
    warn "backed-up value into .env if you need the same groups, then ./punit.sh up."
  fi
  print_info
}

cmd_psql() {
  need_docker; need_env
  local t=()
  [[ -t 0 && -t 1 ]] || t=(-T)
  compose exec ${t[@]+"${t[@]}"} postgres psql -U "$(env_value POSTGRES_USER punit)" -d "$(env_value POSTGRES_DB punit)" "$@"
}

cmd_reset() {
  need_docker; need_env
  local project; project="$(project_name)"
  confirm_word "This DELETES the database, patch files and the dev signing key of project '$project' (volumes ${project}_pgdata, ${project}_artifacts, ${project}_keys). .env and backups/ are kept. Apps built with the old key will refuse new patches." "$project" \
    || { echo "Aborted. Nothing was deleted."; exit 1; }
  compose --profile tools down -v --remove-orphans
  ok "Stack and volumes of '$project' removed. Run ./punit.sh setup to start fresh (new signing key)."
}

cmd_demo() {
  need_docker; need_env
  api_running || die "The stack is not running. Run ./punit.sh setup (or up) first."
  "$ROOT/scripts/seed_demo.sh"
  "$ROOT/scripts/publish_test_patch.sh" "$@"
  "$ROOT/scripts/verify_demo.sh"
}

cmd_verify() { "$ROOT/scripts/verify_demo.sh"; }

cmd_cli() {
  command -v python3 >/dev/null 2>&1 || die "python3 not found (the CLI needs Python 3.10+)"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || die "Python $(python3 -c 'import platform; print(platform.python_version())') is too old; the CLI needs 3.10+"
  python3 -m venv --help >/dev/null 2>&1 || die "python3 venv module missing (Ubuntu: sudo apt install python3-venv)"
  say "Building the CLI wheel (local only, nothing is uploaded)"
  "$ROOT/scripts/build_cli.sh"
  local wheel
  wheel="$(find "$ROOT/cli/dist" -name 'punit_cli-*.whl' | head -n1)"
  [[ -n "$wheel" ]] || die "No wheel in cli/dist"
  [[ -d "$CLI_VENV" ]] || python3 -m venv "$CLI_VENV"
  "$CLI_VENV/bin/pip" install --quiet --upgrade pip
  "$CLI_VENV/bin/pip" install --quiet --force-reinstall "$wheel"
  "$CLI_VENV/bin/ota" --help >/dev/null
  ok "Installed $(basename "$wheel") into $CLI_VENV"
  cat <<EOF

Use it against this stack (URL and admin key are taken from .env):
  ./punit.sh ota app list
Or directly, e.g. for another server:
  export OTA_API_URL=$(api_url) OTA_API_KEY=<OTA_ADMIN_API_KEY from .env>
  $CLI_VENV/bin/ota app list
EOF
}

cmd_ota() {
  need_env
  [[ -x "$CLI_VENV/bin/ota" ]] || die "CLI not installed. Run ./punit.sh cli first."
  OTA_API_URL="$(api_url)" OTA_API_KEY="$(env_value OTA_ADMIN_API_KEY)" "$CLI_VENV/bin/ota" "$@"
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
  setup)        cmd_setup "$@" ;;
  up|start)     cmd_up "$@" ;;
  stop)         cmd_stop ;;
  down)         cmd_down ;;
  restart)      cmd_restart ;;
  status)       cmd_status ;;
  logs)         cmd_logs "$@" ;;
  update)       cmd_update "$@" ;;
  backup)       cmd_backup "$@" ;;
  restore)      cmd_restore "$@" ;;
  psql)         cmd_psql "$@" ;;
  reset)        cmd_reset ;;
  demo)         cmd_demo "$@" ;;
  verify)       cmd_verify ;;
  cli)          cmd_cli ;;
  ota)          cmd_ota "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "Unknown command: $cmd" ;;
esac
