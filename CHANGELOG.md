# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/). Before 1.0, any release may contain breaking changes.

## [Unreleased]

### Security

- `ota_client`: patch ids from the server are not covered by the signature but name files and
  directories. A manipulated update-check response could use an id such as `../..` to delete or
  write files outside the client's storage. The client (Dart and Android) now accepts only
  canonical lowercase UUIDs and refuses any other id before downloading.
- `ota_client`: plain `http://` is refused for the server and for patch downloads, except for
  loopback (`localhost`, `127.0.0.0/8`, `[::1]`, any build) and the emulator host `10.0.2.2`
  (debug builds only).
- `ota_client`: patch downloads now time out (no response 30 s, stalled 30 s, total 10 min) and
  the default HTTP client has a 15 s connect timeout. Before, a stalled download could block
  every later `checkForUpdate()` until the app restarted.

### Changed

- **Breaking for some setups:** apps that pointed `ota_client` at `http://<LAN IP>` (phone on
  Wi-Fi) must use HTTPS or `adb reverse` with `http://localhost`.

## [0.1.0-alpha.1] - 2026-11-11

First public, **experimental** release (an earlier planned `0.1.0-alpha` tag was never created).
Internally tested only; not production-ready. Tested on a Linux development machine and with
Android apps on a small number of devices; iOS, macOS and Windows are not tested.

### Added

- FastAPI control plane: apps, channels, releases, patches, signed patch artifacts,
  deterministic percentage rollouts, rollback, revoke, device registration (JWT), update check,
  aggregated device telemetry, single-page admin UI at `/admin`.
- ES256 signing of a canonical patch message (ADR-0002); content-addressed, immutable storage
  (local disk + nginx, or S3-compatible buckets).
- `ota_client` Flutter package: check, size-limited download, SHA-256 + ES256 verification,
  anti-replay, staging, boot protection with automatic fallback, telemetry. Includes the
  `mock-v1` runtime and an experimental Android AOT code-patch runtime.
- `ota` CLI, including `ota release android` / `ota patch android` (experimental) for Android
  Dart code patches on stock Flutter.
- Local self-hosted stack: `docker-compose.yml` (Postgres, API, nginx CDN) with health checks.
- Demo scripts: `setup_local.sh`, `generate_dev_signing_key.sh`, `seed_demo.sh`,
  `publish_test_patch.sh`, `verify_demo.sh`, `cleanup_local.sh`, `prepublish_check.sh`.
- Documentation: README, architecture, security model, SECURITY.md, contributing guide, code of
  conduct, third-party notices; GitHub issue/PR templates; CI workflow.
- Licensing: Apache-2.0 `LICENSE` and `NOTICE`, SPDX headers in Flutter OTA System source files, audited
  `THIRD_PARTY_NOTICES.md` (incl. the Flutter template and bsdiff licence texts); original Flutter OTA System
  launcher icons in the example app.
- Documentation set organised by Diátaxis (`docs/index.md`): installation tutorial, Flutter
  integration, releases and patches, rollouts, operations, troubleshooting, API / CLI /
  configuration references, concepts, architecture, security and limitations.
- `./flutter-ota-system.sh`: one-command local Docker setup and operations (`setup`, `up`, `stop`, `down`,
  `restart`, `status`, `logs`, `update`, `backup`, `restore`, `psql`, `reset`, `demo`, `verify`,
  `cli`, `ota`). `setup` creates `.env` with random local secrets and never overwrites an
  existing one; the dev signing key is created once and kept. Tested on Linux only.
- Local backup and restore (database, patch files, signing key, `.env`) with checksums.
- `ota` CLI can be built as a local wheel (`scripts/build_cli.sh`); not published to PyPI.
- `docs/known-issues.md`: known bugs with priority, status and proposed fixes.

### Changed (compared with the internal pre-release)

- **Project renamed from "Punit" to Flutter OTA System.** Script `./punit.sh` →
  `./flutter-ota-system.sh`; settings `PUNIT_*` → `FLUTTER_OTA_*`; Compose project `punit` →
  `flutter-ota-system` (volumes `flutter-ota-system_*`); API image `flutter-ota-system-api:local`;
  default database user and name `flutter_ota`; demo application slug `flutter-ota-system-demo`;
  CLI package `flutter-ota-system-cli` (the command is still `ota`). The copyright holder stays
  "The Punit Authors". Existing local installs are upgraded automatically and keep their data and
  signing key ([operations.md](docs/operations.md#local-installs-made-before-the-rename)). The HTTP
  API, the `OTA_*` server settings, the patch formats and the Android application IDs are
  unchanged.
- New project icon (README and example app): an app tile with a missing corner and an amber
  patch piece arriving over the air. Generated from plain shapes by `docs/assets/make_icon.py`.
- Local Compose stack: ports bound to 127.0.0.1 by default, `OTA_CDN_BASE_URL` defaults to `http://localhost:8080/cdn`, and
  the dev signing key is no longer auto-generated (`OTA_AUTO_GENERATE_SIGNING_KEY=false`).
- Docker: pinned image versions, multi-stage API image, Postgres on an internal network with **no
  host port by default** (opt-in: `docker/compose.postgres-port.yml`), `no-new-privileges`, log
  rotation, configurable project name and ports. If you used `localhost:5432`, enable the opt-in.
- Documentation: one consistent "Platform Support & Testing Status" statement (README, docs,
  release notes). Only the Linux development environment and the Android Flutter app are
  internally tested; iOS, macOS and Windows are not tested. Platform testing tasks added to the
  roadmap.

### Fixed (found during release preparation)

- KI-12: `backup` could write a damaged `files.tgz` (when the API image had to be built first, the
  build log ended up in the archive) and still report success. Backups are now checked (database
  dump, gzip, signing key present) and `restore` refuses a damaged backup before changing anything.
- KI-4: the server enforces the promotion checks for protected channels
  (`OTA_PROTECTED_CHANNELS`, default `production`): a patch must have run on another channel and
  have no boot failures before its percentage there is raised. Override with `force` + `reason`
  (logged); CLI `--force --reason`; the admin page asks for a reason.
- KI-1: re-registering a deleted release no longer breaks installs. The client switches to the
  new release id once (old patches dropped, retired ids refused); the server needs
  `replace: true` (CLI `--replace`) if devices still report that version.
- KI-2: policy approvals are stored with reason and time (migration 0003);
  `GET /v1/admin/apps/{slug}/policy-approvals`, `ota app policy-history`.
- KI-7: `cli/otadiff.py` uses only the public `bsdiff4` API; works with bsdiff4 1.2.6 to 1.4.2.
- KI-9: the admin page no longer suggests a wrong default key.
- KI-5: `example_app` defaults to the `flutter-ota-system-demo` slug used by the demo scripts.
- KI-6: the documentation no longer claims a 30-minute background check; the client checks only
  when the app calls `checkForUpdate()`.

### Removed

- Internal-only documentation and the promotional video project (not needed to run Flutter OTA System).
- The Render Blueprint (`render.yaml`) and the Render + Supabase hosting guide. Flutter OTA System is
  self-hosted with Docker; hosted platforms are not documented or supported.

### Known limitations

See [docs/known-issues.md](docs/known-issues.md) and [docs/limitations.md](docs/limitations.md).
Open bugs: KI-8, KI-10, KI-11 (all low priority); KI-3 is an accepted limitation. The KI-1 and KI-4
fixes are covered by automated tests and were checked on one Android phone only. Also: no audit
log, one shared admin key, no rate limiting, no Key Vault/KMS signer, no Azure Blob adapter, no iOS
code patches (iOS not tested), the single-server `deploy/` setup is not verified, and there are no
published load tests.

[Unreleased]: https://github.com/punitsoni22/flutter_ota_system/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/punitsoni22/flutter_ota_system/releases/tag/v0.1.0-alpha.1
