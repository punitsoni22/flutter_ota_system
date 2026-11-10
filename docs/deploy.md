# Hosting the OTA server (single server, Docker)

> [!IMPORTANT]
> **Status: draft, not yet verified end to end.** Docker is Punit's official installation method,
> but this production-style setup (`deploy/docker-compose.prod.yml` + Caddy) has **not** been
> tested from a clean server for v0.1.0-alpha. A tested Docker quickstart for servers is planned.
> Read [security.md](security.md) first, and test on a throwaway server before real use.

One VPS with Docker runs everything: Postgres, the API, an nginx file server for patches, and Caddy
for HTTPS (automatic Let's Encrypt certificates). Files: `deploy/`.

**Server size:** 2 vCPU, 4 GB RAM, 40 GB disk is plenty to start (DigitalOcean, Hetzner, AWS
Lightsail, …). Ubuntu 24.04.

## 1. Prepare

```bash
# DNS: an A record ota.example.com -> the VPS IP. Firewall: open 22, 80, 443 only.
curl -fsSL https://get.docker.com | sh
git clone <this repo> /opt/flutter_ota_system && cd /opt/flutter_ota_system/deploy
cp .env.example .env
for v in POSTGRES_PASSWORD OTA_ADMIN_API_KEY OTA_DEVICE_JWT_SECRET OTA_ROLLOUT_HMAC_SECRET; do
  sed -i "s|^$v=.*|$v=$(openssl rand -hex 32)|" .env
done
nano .env                      # set OTA_DOMAIN
```

## 2. Create the signing key (once, ever)

```bash
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml run --rm api python -m app.keygen
```

It prints `OTA_PUBLIC_KEY` for the apps. **Back the key up offline** (`backup.sh` also copies it).
Apps only trust this key: losing it means new store builds for every app.

## 3. Start

```bash
docker compose -f docker-compose.prod.yml up -d
curl https://ota.example.com/health/ready      # {"status":"ok"}
```

The server refuses to start with unsafe settings (default secrets, http CDN, auto-created key).
Database migrations run on every start, so upgrades are `git pull` and `up -d --build`.

Admin page: `https://ota.example.com/admin` (key: `OTA_ADMIN_API_KEY`).
CLI on your laptop or CI:

```bash
export OTA_API_URL=https://ota.example.com OTA_API_KEY=<OTA_ADMIN_API_KEY>
```

## 4. Backups

```bash
crontab -e
0 3 * * * cd /opt/flutter_ota_system/deploy && ./backup.sh >> backups/backup.log 2>&1
```

Keeps 14 days of database dumps and files (patches, store builds, signing key) in `deploy/backups`.
Copy them off the server too (e.g. `rclone` to S3/Drive): a backup on the same disk is not a backup.

Restore: `docker compose ... exec -T postgres pg_restore -U ota -d ota --clean < db-….dump`, and
untar `files-….tgz` into the `api` container's `/data`.

## What is public

| Path | Who |
|---|---|
| `/v1/devices/*`, `/v1/updates/check`, `/v1/events/*` | Apps (device token) |
| `/cdn/patches/*` | Anyone: signed diffs, useless without the app |
| `/v1/admin/*`, `/admin` | Admin API key only |
| store builds (`releases/`) | Never public: admin download only |
| `/docs` | Off in production |

## Before real users

- There is only **one** admin key today. Keep it in a password manager, give it only to people who
  must publish, and change it if someone leaves. Per-person keys, users and roles are **planned,
  not implemented** ([roadmap Phase 8](roadmap/phase-08-admin-rbac.md)).
- In the apps: `OTA_SERVER_URL=https://…`, the production `OTA_PUBLIC_KEY`, and no
  `usesCleartextTraffic`.
- Monitor `/health/ready` (UptimeRobot or similar) and watch boot failures on the admin page.
