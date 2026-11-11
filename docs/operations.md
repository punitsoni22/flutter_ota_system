# Operations

Running a Flutter OTA System server: deployment, monitoring, logs, backups and recovery. Read
[security.md](security.md) before exposing anything to the internet.

> [!WARNING]
> Flutter OTA System is experimental and has not been validated in production. No load tests have been run, so
> there is no tested capacity figure. Validate it for your own apps before real users depend on
> it.

## Single-server deployment (draft)

> [!IMPORTANT]
> **Status: draft, not yet verified end to end.** Docker is Flutter OTA System's official installation
> method, but this production-style setup has **not** been tested from a clean server for
> v0.1.0-alpha.1. Test it on a throwaway server first. Planned work:
> [roadmap/installation-improvements.md](roadmap/installation-improvements.md).

Linux is the only host OS the maintainers have tested Flutter OTA System on (with the local stack); other
host operating systems are not tested.

One Linux server runs everything with Docker Compose ([`deploy/`](../deploy/)):

```mermaid
flowchart LR
  net(("Internet")) -- "443 / 80" --> caddy["caddy<br/>HTTPS (Let's Encrypt)"]
  caddy -- "/cdn/patches/*" --> cdn["cdn (nginx)"]
  caddy -- "everything else" --> api["api (FastAPI, OTA_ENV=production)"]
  api --> pg[("postgres")]
  api -- writes --> vol[["artifacts volume"]]
  cdn -- reads --> vol
  api --- keys[["keys volume (signing key)"]]
```

Only Caddy publishes ports. `/cdn/*` paths other than `/cdn/patches/*` return 404, so store
builds are never public.

**Server size:** no measured requirement exists. The deploy files were written for a small VPS
(2 vCPU, 4 GB RAM, 40 GB disk, Ubuntu 24.04); treat that as a starting point, not a tested figure.

### 1. Prepare

```bash
# DNS: an A record ota.example.com -> the server's IP. Firewall: open 22, 80, 443 only.
curl -fsSL https://get.docker.com | sh
git clone https://github.com/punitsoni22/flutter_ota_system.git /opt/flutter_ota_system
cd /opt/flutter_ota_system/deploy
cp .env.example .env
for v in POSTGRES_PASSWORD OTA_ADMIN_API_KEY OTA_DEVICE_JWT_SECRET OTA_ROLLOUT_HMAC_SECRET; do
  sed -i "s|^$v=.*|$v=$(openssl rand -hex 32)|" .env
done
nano .env                      # set OTA_DOMAIN
```

### 2. Create the signing key (once, ever)

```bash
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml run --rm api python -m app.keygen
```

It writes the key into the `keys` volume and prints `OTA_PUBLIC_KEY for the apps: prod-1:…`.
**Back the key up offline.** Apps trust only this key; losing it means new store builds for every
app.

### 3. Start

```bash
docker compose -f docker-compose.prod.yml up -d
curl https://ota.example.com/health/ready      # {"status":"ok"}
```

The API refuses to start with unsafe settings and names them
([configuration.md](configuration.md#production-safety-checks)). Migrations run on every start.
The admin page is at `https://ota.example.com/admin`; `/docs` is off in production.

From your laptop or CI:

```bash
export OTA_API_URL=https://ota.example.com OTA_API_KEY=<OTA_ADMIN_API_KEY from deploy/.env>
ota app list
```

### What is public

| Path | Who can call it |
|---|---|
| `/v1/devices/*`, `/v1/updates/check`, `/v1/events/*` | Apps (registration is open; the rest needs a device token) |
| `/cdn/patches/*` | Anyone: signed diffs |
| `/v1/admin/*`, `/admin` | Admin API key (restrict at the network level too) |
| Store builds | Never public: admin API only |
| `/docs`, `/openapi.json` | Off in production |

### Other hosting

Any host that runs the API container with PostgreSQL and either a persistent disk + file server,
or S3-compatible buckets, can work; configure it with the variables in
[configuration.md](configuration.md). Only the Docker setups in this repository are documented
and supported: Flutter OTA System is meant to be self-hosted.

## Monitoring

Flutter OTA System has no metrics endpoint, dashboards or alerts. What exists:

| What | How |
|---|---|
| Process up | `GET /health/live` → `{"status":"ok"}` |
| Database reachable | `GET /health/ready` → `{"status":"ok"}`. Point an uptime monitor at it |
| Container health | `docker compose ps` (the API, nginx and Postgres containers have health checks) |
| Patch health | Per-patch counters: `ota patch show <id>` → `event_counts`, or the admin page |
| Adoption | `GET /v1/admin/apps/<slug>/devices/summary` or the admin page **Devices** table |

## Logs and telemetry

**Server logs** go to standard output (Uvicorn access logs plus the `ota` logger, which logs the
signing key id at startup):

```bash
docker compose logs -f api                                   # local
docker compose -f docker-compose.prod.yml logs -f api caddy  # single server
```

Logs are not structured (no JSON, no request ids) and there is no log shipping. Caddy's access
logs are your best record of admin actions, because there is no audit log.

**Device telemetry** is limited to seven event types per patch (`patch_downloaded`,
`patch_hash_failed`, `patch_signature_failed`, `patch_staged`, `patch_boot_succeeded`,
`patch_boot_failed`, `patch_auto_rollback`). The server keeps only **counts** per patch and type;
there is no per-device history. Events are best effort: the client keeps unsent events and retries
on the next call.

**Device logs** (Android, for debugging): `adb logcat | grep -E "OtaBoot|OTA:"`. `OtaBoot` logs
lines such as `Running patch <id>`, `Patch <id> did not confirm its last start: skipping it`, and
`OTA boot failed, running the store code`. Lines starting with `OTA:` come from the integration
helper in [flutter-integration.md](flutter-integration.md).

## Backup and restore

What must be backed up:

| Data | Where | Why |
|---|---|---|
| PostgreSQL | volume `pgdata` | Apps, releases, patches, signatures, rollouts, devices |
| Files | volume `artifacts` (`patches/` and `releases/`) | Patches and the store builds' code (needed to build new patches) |
| Signing key | volume `keys`, or your secret manager | Losing it means new store builds for every app |

### Single server

[`deploy/backup.sh`](../deploy/backup.sh) dumps the database and archives the files and key into
`deploy/backups/`, keeping 14 days:

```bash
crontab -e
0 3 * * * cd /opt/flutter_ota_system/deploy && ./backup.sh >> backups/backup.log 2>&1
```

Copy the backups off the server as well (for example with `rclone`), and protect them: they
contain the signing key.

Restore (**not yet tested**; practise it on a test server):

```bash
cd /opt/flutter_ota_system/deploy
docker compose -f docker-compose.prod.yml exec -T postgres pg_restore -U ota -d ota --clean < backups/db-<stamp>.dump
docker compose -f docker-compose.prod.yml exec -T api tar -C /data -xzf - < backups/files-<stamp>.tgz
docker compose -f docker-compose.prod.yml restart api
```

### Local stack

`./flutter-ota-system.sh` covers the local stack ([installation.md](installation.md#6-day-to-day-commands)).
These commands were tested on Linux with a backup → change → restore round trip:

```bash
./flutter-ota-system.sh backup                 # -> backups/<project>-<YYYYmmdd-HHMMSS>/
./flutter-ota-system.sh restore backups/flutter-ota-system-20261111-092352   # asks you to type "restore"
```

A backup folder (mode 700, files mode 600) contains:

| File | Content |
|---|---|
| `db.dump` | `pg_dump --format=custom` of the database |
| `files.tgz` | The `artifacts` (patches and store-build files) and `keys` (dev signing key) volumes |
| `env` | A copy of `.env` (secrets!) |
| `SHA256SUMS` | Checksums; `restore` refuses a damaged backup |

`backup` works while the stack runs or is stopped (it starts Postgres if needed). `restore` stops
`api` and `cdn`, recreates the database from `db.dump`, replaces the files and the signing key
from `files.tgz`, starts everything and waits for health checks. It does **not** change `.env`; if
your `.env` differs from the backed-up `env`, it tells you (copy `OTA_ROLLOUT_HMAC_SECRET` back if
you need the same rollout groups). `./flutter-ota-system.sh update` takes a backup automatically before it
rebuilds (skip with `--no-backup`).

The backups contain the signing key and secrets: keep `backups/` private (it is git-ignored and
never part of a Docker build context) and copy it off your computer if the data matters.

By hand, the same backup is:

```bash
docker compose exec -T postgres pg_dump -U flutter_ota -d flutter_ota --format=custom > flutter-ota-system-db.dump
docker compose run --rm --no-deps -T --entrypoint tar api -C /data -czf - artifacts keys > flutter-ota-system-files.tgz
```

### Local stack: restarts and recovery (tested on Linux)

| Situation | What happens |
|---|---|
| `./flutter-ota-system.sh stop` / `up`, `down` / `up`, `restart`, computer reboot | Database, patch files and the signing key are kept (named volumes). Containers use `restart: unless-stopped`, so a running stack comes back after a Docker or computer restart |
| Postgres restarts while the API runs | The API reconnects by itself (`pool_pre_ping`). `/health/ready` fails (HTTP 500) for a few seconds while Postgres starts |
| API restarts | Migrations run again under a PostgreSQL advisory lock; nothing is lost |
| Signing key | Created once; `setup`, `up`, `update` never replace it. Only `./flutter-ota-system.sh reset` deletes it |

## Failure recovery

| Failure | Effect on apps | Recovery |
|---|---|---|
| API down | Checks fail (`UpdateStatus.failed`); apps keep running their current code | Fix and restart; nothing is lost on the devices |
| Database down | `/health/ready` fails; checks fail | Restore the database; restart the API |
| File server down | Downloads fail; nothing is staged | Restart nginx; devices retry on their next check |
| Bad patch published | Devices that started it and crashed fall back on their own | `ota patch rollback` or `revoke` ([rollouts.md](rollouts.md)) |
| Lost artifacts volume | Published patches can't be downloaded; new patches can't be diffed against lost store builds | Restore from backup. Without the release's `libapp.so`, that release can't get new code patches |
| Lost signing key | No new patches can be trusted by existing apps | Restore from backup; otherwise new store builds with a new key |
| Leaked admin key or signing key | — | [security.md](security.md#compromised-signing-key-procedure) and rotate ([secret rotation](security.md#secret-rotation)) |

## Upgrading Flutter OTA System

Local stack:

```bash
git pull
./flutter-ota-system.sh update        # backup, rebuild the API image, recreate the containers, wait for health
```

Single server:

```bash
cd /opt/flutter_ota_system && git pull
cd deploy && ./backup.sh && docker compose -f docker-compose.prod.yml up -d --build
```

Database migrations run automatically on start. Before v1.0 the API, schema and patch formats may
change between versions; read the [CHANGELOG](../CHANGELOG.md) and back up first. Upgrades across
released versions have not been tested yet (`./flutter-ota-system.sh update` was tested only as a rebuild of
the same version).

### Local installs made before the rename

The project was previously called "Punit". A local install from that time has `PUNIT_*` settings
in `.env` and its data in the Docker volumes `punit_pgdata`, `punit_artifacts` and `punit_keys`.
The scripts upgrade it automatically the first time you run any `./flutter-ota-system.sh` command:

- the `PUNIT_*` lines in `.env` become `FLUTTER_OTA_*` (a copy is kept as `.env.pre-rename-<time>`);
- if the old volumes exist, `.env` gets `COMPOSE_PROJECT_NAME=punit`, so the existing database,
  patch files and **signing key** stay in use. Nothing else changes; you can stop here.

To move the data to the new project name (optional; tested on Linux):

```bash
COMPOSE_PROJECT_NAME=punit ./flutter-ota-system.sh backup    # back up the old project
# remove the "COMPOSE_PROJECT_NAME=punit" line (and the comment above it) from .env
./flutter-ota-system.sh setup                                # new, empty flutter-ota-system project
./flutter-ota-system.sh restore backups/punit-<time>         # same data, same signing key
./flutter-ota-system.sh status                               # check: same OTA_PUBLIC_KEY as before
```

When everything works, delete the old volumes: `docker volume rm punit_pgdata punit_artifacts
punit_keys`. Your `.env` keeps its database user (`POSTGRES_USER`), so the restored database
matches it.

## Production considerations

- [ ] Random 32+ character secrets; `OTA_ENV=production` (the API checks this)
- [ ] HTTPS for the API and file server; no `usesCleartextTraffic` in apps
- [ ] Signing key created once, backed up offline, readable only by the API
- [ ] Apps ship with the production key **and** a backup key ([security.md](security.md#trusted-keys-in-apps-and-rotation))
- [ ] Admin access restricted at the network level; admin key shared with as few people as possible
- [ ] Off-server backups, and a tested restore
- [ ] Uptime monitoring on `/health/ready`
- [ ] A written rollout procedure (staging → 1% → … → 100%) and who may run it
- [ ] Store-policy decision recorded for each `public_store` app
- [ ] Your own load test if you expect many devices: Flutter OTA System publishes no capacity figures
