# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/). Before 1.0, any release may contain breaking changes.

## [Unreleased]

### Fixed

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

### Added

- `ota` CLI can be built as a local wheel (`scripts/build_cli.sh`); not published to PyPI.
- `docs/known-issues.md`: known bugs with priority, status and proposed fixes.

### Changed

- Documentation: one consistent "Platform Support & Testing Status" statement (README, docs,
  release notes). Only the Linux development environment and the Android Flutter app are
  internally tested; iOS, macOS and Windows are not tested. Platform testing tasks added to the
  roadmap.

## [0.1.0-alpha] - YYYY-MM-DD

First public, **experimental** release. Internally tested only; not production-ready. Tested on
a Linux development machine and with Android apps (a small number of devices); iOS, macOS and
Windows are not tested.

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
- Licensing: Apache-2.0 `LICENSE` and `NOTICE`, SPDX headers in Punit source files, audited
  `THIRD_PARTY_NOTICES.md` (incl. the Flutter template and bsdiff licence texts); original Punit
  launcher icons in the example app.
- Documentation set organised by Diátaxis (`docs/index.md`): installation tutorial, Flutter
  integration, releases and patches, rollouts, operations, troubleshooting, API / CLI /
  configuration references, concepts, architecture, security and limitations.

### Changed (compared with the internal pre-release)

- Local Compose stack renamed to project `punit` (new volume names), DB user `punit`, ports
  bound to 127.0.0.1 by default, `OTA_CDN_BASE_URL` defaults to `http://localhost:8080/cdn`, and
  the dev signing key is no longer auto-generated (`OTA_AUTO_GENERATE_SIGNING_KEY=false`).

### Removed

- Internal-only documentation and the promotional video project (not needed to run Punit).
- The Render Blueprint (`render.yaml`) and the Render + Supabase hosting guide. Punit is
  self-hosted with Docker; hosted platforms are not documented or supported.

### Known limitations

See the README and `docs/known-issues.md` (KI-1 to KI-7). Most important: the `promote` checks
are not enforced by the server (KI-4), re-creating a deleted release breaks existing installs
(KI-1), no audit log, single admin key, no rate limiting, no Key Vault/KMS signer, no Azure Blob
adapter, no iOS code patches (iOS not tested), and no published load tests.

[Unreleased]: https://github.com/punitsoni22/flutter_ota_system/compare/v0.1.0-alpha...HEAD
[0.1.0-alpha]: https://github.com/punitsoni22/flutter_ota_system/releases/tag/v0.1.0-alpha
