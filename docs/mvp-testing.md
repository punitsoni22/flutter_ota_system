# MVP testing guide

This MVP is the full OTA platform running locally in Docker: version matching, signing, rollout, rollback, revoke, and boot protection.

This guide uses `example_app`, where a patch is a **signed JSON file** (`mock-v1`) that the app reads to change its banner and colour. **Real Dart code patches** (Android) now work too, with stock Flutter: see [code-push.md](code-push.md). Hosting: [deploy.md](deploy.md). **Start here:** [setup-guide.md](setup-guide.md).

```
example_app (emulator/phone) ──► api :8000 (FastAPI) ──► postgres
            │                        │ writes files
            └── download ──► cdn :8080 (nginx) ◄── artifacts volume
```

| Folder | What it is |
|---|---|
| `backend/` | FastAPI server. Tests: `backend/tests/` |
| `cli/ota.py` | The `ota` admin CLI |
| `packages/ota_client/` | Flutter client package. Tests: `packages/ota_client/test/` |
| `example_app/` | Demo app using the client (app slug `demo`) |
| `backend/app/admin.html` | Admin web page, served at http://localhost:8000/admin |
| `scripts/simulate_fleet.py` | Fakes many devices to test rollout percentages |
| `docker-compose.yml` | Postgres + API + CDN |

---

## 1. One-time setup

**Docker** (needs your password):

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
# log out and back in, then:
docker run --rm hello-world
```

**CLI** (from the repo root):

```bash
python3 -m venv .venv
.venv/bin/pip install -r cli/requirements.txt -r backend/requirements-dev.txt
alias ota="$PWD/.venv/bin/python $PWD/cli/ota.py"     # add to ~/.bashrc to keep it
```

**Check:** `ota --help` prints the commands.

---

## 2. Run the automated tests (no Docker needed)

```bash
(cd backend && ../.venv/bin/python -m pytest -q)        # expect: all passed
(cd packages/ota_client && flutter test)                 # expect: All tests passed!
```

---

## 3. Start the stack

**Which CDN address?** The phone downloads patch files from `OTA_CDN_BASE_URL` in `.env`:
- **Android emulator:** `OTA_CDN_BASE_URL=http://10.0.2.2:8080/cdn` (`10.0.2.2` is your PC as seen from the emulator).
- **Real phone on the same Wi‑Fi:** find your PC's IP with `hostname -I`, then set
  `OTA_CDN_BASE_URL=http://<PC-IP>:8080/cdn` and `PUNIT_BIND_ADDRESS=0.0.0.0`.
- The default `http://localhost:8080/cdn` is for the scripts and desktop testing.

```bash
cp .env.example .env                 # once; then edit OTA_CDN_BASE_URL as above
./scripts/setup_local.sh             # builds, creates the LOCAL dev signing key, starts the stack
curl localhost:8000/health/ready     # {"status":"ok"}
curl localhost:8080/health           # ok
export OTA_API_KEY=local-dev-admin-key-not-a-secret   # OTA_ADMIN_API_KEY from .env, for the CLI
```

After changing `.env`, apply it with `docker compose up -d`.

API docs: http://localhost:8000/docs

---

## Admin page

Open **http://localhost:8000/admin** and enter the admin API key (`OTA_ADMIN_API_KEY` from `.env`). It shows every app, its releases and patches, and lets you:

- create apps and releases, and copy the `OTA_PUBLIC_KEY` for the app
- create a patch (paste JSON or pick a file) and publish it to a channel at a %
- change the rollout %, roll back, publish again, or revoke a patch
- see how many devices run each release / patch, and boot successes / failures per patch (crashing patches are highlighted)

It uses the same admin API as the CLI, so the CLI and the page can be mixed freely.

### Staging → production

One app, one store release, two channels. A patch is tested on `staging`, then the **same signed file** is promoted to `production`. Nothing is rebuilt, so production gets exactly what was tested.

1. Publish the new patch to **staging** (the default in the admin page's *New patch* form).
2. On tester phones, switch the app to **staging** (in your app, call `ota.setChannel('staging')`). Normal users stay on `production`, the build's default.
3. Restart the tester app and check the patch. Its *Boot ok / failed* counts show up within seconds.
4. Click **Promote to production** (start at 10%, then raise it), or run `ota patch promote <patch_id> --percent 10`. The CLI refuses a patch that was never on staging or has boot failures, unless you pass `--force`.

The tester's channel choice is saved on the phone and kept across app updates. Switching back to `production` keeps the current patch until production has a newer one.

---

## 4. Register the app and its store release

```bash
ota app create demo "Demo App"
ota release create demo --platform android --version 1.0.0+1
ota key show
```

`1.0.0+1` must equal `version:` in `example_app/pubspec.yaml`. Copy `key_id` and `uncompressed_point_base64` from `ota key show`. The app needs them as `OTA_PUBLIC_KEY=<key_id>:<point>`.

---

## 5. Run the example app

Start an emulator (or plug in a phone with USB debugging), then:

```bash
cd example_app
flutter run --release \
  --dart-define=OTA_PUBLIC_KEY='dev-1:PASTE_POINT_HERE' \
  --dart-define=OTA_CHANNEL=dev
# Real phone: also --dart-define=OTA_SERVER_URL=http://<PC-IP>:8000
```

**Check:** the app shows "Store build (no patch)", Active patch `none`, and "Up to date" after you tap **Check for update now**.

> **"Restart the app"** below means: swipe it away in the recent-apps screen, then open it again from the launcher. The new code only runs after a restart, never while the app is running.

---

## 6. Test cases

Make the patch files once:

```bash
mkdir -p /tmp/ota && cd /tmp/ota
echo '{"banner":"Hello from patch 1","color":"#4CAF50"}' > p1.json
echo '{"banner":"Patch 2","color":"#2196F3"}'           > p2.json
echo '{"banner":"Patch 3","color":"#9C27B0"}'           > p3.json
echo '{"crash":true}'                                     > crash.json
```

The emulator is `x86_64`, and most phones are `arm64-v8a`. Every patch below uploads the file for both. A small helper saves typing:

```bash
mkpatch() { ota patch create demo --platform android --release 1.0.0+1 \
              --file x86_64="$1" --file arm64-v8a="$1" --channel "${2:-dev}" --percent "${3:-100}"; }
# usage: mkpatch p1.json           mkpatch p1.json production 10
```

| # | Case | Do | Expected |
|---|---|---|---|
| A | **First patch** | `mkpatch p1.json` → in the app, tap **Check** → restart | "Patch 1 ready", then after restart a green "Hello from patch 1", Active patch `#1` |
| B | **Already latest** | Tap **Check** | "Up to date" |
| C | **Skip to latest** | Close the app. `mkpatch p2.json` and `mkpatch p3.json`. Open, Check, restart | Goes **straight to #3** (purple) |
| D | **Crash protection** | `mkpatch crash.json`. Check, restart | App closes immediately (the "broken patch"). Open it again: back on **#3**. `ota patch show <id>` shows `patch_boot_failed: 1` |
| E | **Crashed patch not retried** | Tap **Check** | "Refused: patch previously failed on this device" |
| F | **Rollback** | `ota patch list demo --platform android --release 1.0.0+1`, then `ota patch rollback <id of #3>`. Check, restart | Back on **#2** (blue) |
| G | **Revoke** | `ota patch revoke <id of #2> --yes` and `ota patch revoke <id of #1> --yes`. Check, restart | "Store build (no patch)" |
| H | **Version isolation** | Change `version:` in `pubspec.yaml` to `1.1.0+2`, `ota release create demo --platform android --version 1.1.0+2`, run the app again | Store build, **no** 1.0.0 patches offered |
| I | **Server down** | `docker compose stop api`, restart the app | App opens normally on its current code. Check says "Failed: …". `docker compose start api` afterwards |
| J | **Tampered file on CDN** | Create a patch, then `docker compose exec api sh -c 'echo evil >> /data/artifacts/patches/<payload_sha256>'`. Check | "Refused: download size mismatch". Nothing is staged |
| K | **Wrong signing key** | Run the app with a different `OTA_PUBLIC_KEY` and create a patch | "Refused: unknown signing key" or "signature invalid" |
| L | **Rollout %** | `mkpatch p1.json production 10`, then `python scripts/simulate_fleet.py --app demo --release 1.0.0+1 --devices 1000` | ~10% get the patch. `ota patch rollout <id> --channel production --percent 50` and run again: ~50%, and the first 10% are still in |
| M | **Policy gate** | `ota app create shop "Shop" --distribution public_store`, a release, then a patch with `--format aot-bidiff-android-v1 --result-sha256 <64 hex>` (upload a base first: `release create … --base arm64-v8a=somefile`) | Publish fails with `403 policy_review_required` until `ota app approve-policy shop --reason "..."` |

Look inside at any time:

```bash
docker compose exec postgres psql -U ota -d ota -c "select number, status from patches order by created_at;"
docker compose exec postgres psql -U ota -d ota -c "select installation_id, release_version, current_patch_number, last_seen from devices;"
docker compose logs -f api
```

---

## 7. Reset everything

```bash
docker compose down -v      # deletes the database, files and signing key
```

The signing key is recreated on the next start, so update `OTA_PUBLIC_KEY` in the app.

---

## What the MVP does not have yet

Status marks are explained in the [roadmap](roadmap/README.md).

| Item | Status | Roadmap |
|---|---|---|
| Real Dart code patches | 🟡 Experimental, Android only: [code-push.md](code-push.md) | [Track R](roadmap/runtime-android-engine.md) |
| iOS code patches | 🔭 Research only | [iOS research](roadmap/runtime-ios-research.md) |
| DB migrations | ✅ Alembic, run on start | — |
| Key Vault signing, Azure Blob + Front Door, Azure deployment | 🔭 Planned, not implemented. (GitHub Actions CI exists; it only builds and tests) | [Phase 10](roadmap/phase-10-azure-cicd.md) |
| Users, roles (RBAC), SSO, audit log (now one shared API key) | 🔭 Planned | [Phase 8](roadmap/phase-08-admin-rbac.md) |
| Rate limiting, Redis cache for the check, load tests toward the 1M-installs goal | 🔭 Planned. No scale is claimed | [Phase 11](roadmap/phase-11-hardening.md) |
| Event Hubs for telemetry (now counters in Postgres) | 🔭 Planned | [Phase 9](roadmap/phase-09-telemetry.md) |
| Secure storage for the device token (now in the app's private folder) | 🔭 Planned | [Phase 5.8](roadmap/phase-05-flutter-client.md#58-api-client--auth) |

**Before any real users:** change `OTA_ADMIN_API_KEY`, `OTA_DEVICE_JWT_SECRET` and `OTA_ROLLOUT_HMAC_SECRET`, set `OTA_AUTO_GENERATE_SIGNING_KEY=false`, use HTTPS, and remove `usesCleartextTraffic` from the app manifest.
