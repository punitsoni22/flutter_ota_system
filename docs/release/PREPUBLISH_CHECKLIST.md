# v0.1.0-alpha go / no-go checklist

Run on a **fresh clone** of exactly what will be published. Automated items are covered by
`./scripts/prepublish_check.sh`, which exits non-zero on failure. Manual security tasks are listed
in [MANUAL_SECURITY_CHECKLIST.md](MANUAL_SECURITY_CHECKLIST.md).

| # | Item | How | Auto |
|---|---|---|---|
| 1 | No real secrets in tracked files | gitleaks `dir` + PEM detector | ✔ |
| 2 | No real secrets in reachable history | gitleaks `git` + PEM detector over `git log --all -p` | ✔ |
| 3 | Previously exposed secrets revoked/rotated | [MANUAL_SECURITY_CHECKLIST.md](MANUAL_SECURITY_CHECKLIST.md) §A + `.local/release/SECRET_ROTATION_CHECKLIST.md` (private, git-ignored) | manual |
| 4 | No production URLs / internal names remain (tree **and** history, incl. author emails) | `.local/forbidden-patterns.txt` + `.local/release/history-cleanup.md` (private, git-ignored) | ✔ (needs your pattern file) |
| 5 | `.env.example` contains safe values only | value allow-list check | ✔ |
| 6 | `.env` is git-ignored and untracked | `git check-ignore`, `git ls-files` | ✔ |
| 7 | Dev signing key generated locally, never in the tree | key lives in Docker volume `flutter-ota-system_keys` | ✔ (no key files tracked) |
| 8 | Production signing keys absent | no PEM material anywhere in history | ✔ |
| 9 | Dependency/licence audit completed | [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) (audited 2026-11-11); CI licence gate (no GPL/AGPL) | done |
| 10 | Shorebird-derived/copied code reviewed | THIRD_PARTY_NOTICES §1 (resolved for v0.1.0-alpha) | done |
| 11 | Required notices included | `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`; SPDX headers in Flutter OTA System source files | ✔ |
| 12 | Backend tests pass | pytest in `python:3.13-slim` | ✔ |
| 13 | ota_client analyze/test pass | `flutter analyze && flutter test` | ✔ (if Flutter installed) |
| 14 | patch tooling tests | CI `cli` job (OTADIF01 round trip) | CI |
| 15 | Admin build/test | n/a: static `admin.html`, served by the API | n/a |
| 16 | Docker images build | `setup_local.sh` | ✔ |
| 17 | Compose starts from a fresh clone | `cleanup_local.sh --yes` then `setup_local.sh` | ✔ |
| 18 | Migrations run | API startup (Alembic) → `/health/ready` | ✔ |
| 19 | Demo data seeds | `seed_demo.sh` | ✔ |
| 20 | Example device registers | `verify_demo.sh` | ✔ |
| 21 | Update check succeeds | `verify_demo.sh` | ✔ |
| 22 | Test patch is published | `publish_test_patch.sh` | ✔ |
| 23 | Artifact downloads from local object storage | `verify_demo.sh` (via nginx, not the API) | ✔ |
| 24 | SHA-256 verification succeeds | `verify_demo.sh` | ✔ |
| 25 | Signature verification succeeds | `verify_demo.sh` (independent canonical encoder) | ✔ |
| 26 | Corrupted artifact/signature rejected | `verify_demo.sh` negatives | ✔ |
| 27 | Rollback/revoke work | `verify_demo.sh` | ✔ |
| 28 | README marks project experimental | grep check + human read | ✔ + manual |
| 29 | SECURITY.md has a working private route | [MANUAL_SECURITY_CHECKLIST.md](MANUAL_SECURITY_CHECKLIST.md) §C | manual (placeholder check ✔) |
| 30 | Clean-clone quickstart via docs only | someone else, another machine, README only | manual |
| 31 | Release notes ready | [v0.1.0-alpha.md](v0.1.0-alpha.md), tag marked **pre-release** | manual |
| 32 | Example app runs on an emulator against the local stack | README "Run the example app" | manual |
| 33 | GitHub security settings (2FA, secret scanning, push protection, Dependabot, Actions permissions) | [MANUAL_SECURITY_CHECKLIST.md](MANUAL_SECURITY_CHECKLIST.md) §C | manual |
| 34 | No pre-built Docker images published (or §7 of THIRD_PARTY_NOTICES done first) | [THIRD_PARTY_NOTICES.md §7](../../THIRD_PARTY_NOTICES.md#7-future-actions-before-publishing-pre-built-docker-images) | manual |
| 35 | Package identifiers verified: ownership of `flutterota.dev` (used by `dev.flutterota.*` application ID / Java package) confirmed, or a rename planned before a stable release | README "Known limitations" | manual (open) |

**Go** = every row passes or is explicitly n/a. Any failing row = **no-go**.
