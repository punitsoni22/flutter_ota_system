# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/). Before 1.0, any release may contain breaking changes.

## [Unreleased]

### Added
- **Flutter 3.50.0 / Dart 3.14.0 toolchain** (`flutter-3.50.0-ota.1`, engine build ID
  `c9ecf2e22a18d86fc619668200137cfed5ab48b7`) next to Flutter 3.47.9. The bytecode verifier patch
  was ported to Dart 3.14. The security tests (reference verifier fixtures including B25/B27, and the
  12-file malformed-patch corpus on a device) give the same results as on 3.47.9. Tested on an
  x86_64 emulator with arm64 translation; not yet on a physical phone.
- One signed toolchain index can list several Flutter versions; `toolchain-manifest.json` (format 2)
  lists each with its engine build ID.
- CLI:
  - `toolchain install` and `upgrade` choose the newest toolchain the project can build with
    (pubspec sdk constraint, Android build tool minimums);
  - `doctor` checks the Android build tool minimums of the pinned Flutter (3.50: Gradle 9.3.1, AGP
    9.1.1, KGP 2.4.10).

### Changed
- `flutter_ota patch android` builds a patch with the toolchain its store release was built with
  (installing it if needed), so a project that moved to 3.50 can still patch its 3.47.9 release.
- `flutter_ota toolchain clean --unused` keeps toolchains that local store releases still need.
- Raising Android build tool versions (and the new `flutter_ota.lock`) no longer blocks a patch for
  an older release. Other native changes still do. This applies to releases made from this version
  on.

## CLI 0.2.0-alpha.1 - 2026-11-13

- `flutter_ota_cli` 0.2.0-alpha could not be installed with `dart pub global activate` (a constant
  lived in a file that is not published). Fixed in `flutter_ota_cli` 0.2.0-alpha.1; the SDK and the
  toolchain are unchanged.

## [0.2.0-alpha] - 2026-11-13

First release of the **bytecode architecture**. It is an **experimental alpha**, not
production-ready, not independently security-audited and not reviewed or approved by any app
store. Supported: Android **arm64** apps, built on **Linux x64** machines, with Flutter 3.47.9 /
Dart 3.13.7 and our custom engine. Tested end to end on one Android 13 arm64 phone, with
compatibility runs on Android 14, 16 and 17 x86_64 emulators (arm64 translation; not proof for
real devices or other manufacturers). Release notes: [docs/release/v0.2.0-alpha.md](docs/release/v0.2.0-alpha.md).

### Added: bytecode architecture (experimental)

- **Packages:** the SDK `flutter_ota_system` and the developer CLI `flutter_ota_cli` (command
  `flutter_ota`), both `0.2.0-alpha`, published on pub.dev.
- **Custom engine toolchain:** Flutter 3.47.9 with the Dart bytecode interpreter and an in-VM
  bytecode verifier (engine patch in `prototypes/security_hardening/engine_patch`). Distributed as
  a signed overlay on the stock SDK. The `v0.2.0-alpha` GitHub release carries the toolchain
  files: `toolchain-index.json` (ES256-signed; the only file the CLI trusts), the overlay
  `flutter-3.47.9-ota.1-linux-x64.tar.gz`, `toolchain-manifest.json` (versions, engine commit,
  engine build ID, sizes, SHA-256) and `SHA256SUMS`. The CLI pins this index, downloads the
  official Flutter SDK archive from Google, checks size and SHA-256 of every file, resumes
  interrupted downloads and refuses older index serials. The owner tool
  `RELEASE_LAYOUT=1 tools/toolchain/build_bundle.sh` writes the release files.
- **Developer CLI `flutter_ota`** (`packages/flutter_ota_cli`): `init` (`flutter_ota.yaml` with
  only `app_id`), `config`, `toolchain list|install|doctor|clean`, `upgrade`, `keys init|list`,
  `doctor`, `release android`, `features [generate]`, `patch android`, `status`, `rollback`.
  Builds, bytecode compilation and signing happen on the developer's machine; no source upload.
- **Feature patching:** feature packages with an `OtaFeature` entry class, automatic dependency
  closure, generated feature registry, freezed / json_serializable support with stale-codegen
  detection, refusal of changes that need a store release.
- **SDK (`flutter_ota_system`, additive):** `FlutterOta.initialize()`, `FlutterOta.feature<T>()`,
  `OtaFeature`, status and start-up timing getters; patch verification (certificates, revocation
  lists, toolchain id), separate-process verification, activation at the next start, crash
  recovery. The `0.1.0-alpha.1` `OtaClient` API is unchanged.
- **Backend (additive):** developer-signed `dbc-v1` patches that the server verifies and never
  signs; trust roots, root-signed certificates and revocation lists; releases with a baseline
  identity; device registration by app UUID; migration `0004`. Legacy clients get unchanged
  responses.

### Security: bytecode architecture

- Developer-owned signing: offline root key per app, certified local signer keys, rotation,
  root-signed revocation of serials and keys; the server never holds patch-signing keys for
  `dbc-v1`.
- `patch_guard` now rejects compile errors and scans every non-host package compiled into a module
  (undeclared dependencies were not scanned before); host-only conditional imports are no longer
  falsely rejected.
- Store releases are built from a neutral copy of the workspace, so no developer home path is
  embedded in `libapp.so`.
- The bytecode runtime allows plain `http://` only to loopback addresses in release builds (local
  testing with `adb reverse`); `OtaClient` stays https-only.

### Repository and documentation

- Documentation rewritten for the bytecode architecture: new [quick start](docs/quick-start.md),
  updated README, architecture, security, CLI reference, feature patching, toolchain and
  limitations pages; duplicated guides merged. Internal phase reports, research spikes and test
  records moved out of the public docs (they remain in the Git history).

- One official demo app: the root `example_app/` was merged into the package example
  `packages/ota_client/example/`, which now has the full demo (local stack defaults,
  `--dart-define` settings, crash-protection test hook) and keeps its Android project in Git. The
  unused iOS template folder of `example_app/` was removed (iOS is not supported). CI, Dependabot,
  scripts and docs point to the new path.
- Internal planning documents (the original phase-by-phase build plans), the internal
  pre-publication audit, launch-announcement drafts and the alternative patch engine research
  were removed from the public tree. `docs/roadmap/README.md` is now a short public roadmap.
- New public summary `prototypes/README.md` (research prototypes are not demos).

### Security

- `ota_client`: patch ids from the server are not covered by the signature but name files and
  directories. A manipulated update-check response could use an id such as `../..` to delete or
  write files outside the client's storage. The client (Dart and Android) now accepts only
  canonical lowercase UUIDs and refuses any other id before downloading.
- `ota_client`: release and profile builds accept `https://` only, for the server and patch
  downloads (no localhost exception). Debug builds also allow `http://` to loopback
  (`localhost`, `127.0.0.0/8`, `[::1]`) and the emulator host `10.0.2.2`.
- `ota_client`: redirects are followed by the client itself (GET only, at most 5), and every
  destination is checked against the same rules. An `https://` URL never redirects to `http://`,
  and the device token is not forwarded when a redirect changes the host.
- `ota_client`: patch downloads now time out (no response 30 s, stalled 30 s, total 10 min) and
  the default HTTP client has a 15 s connect timeout. Before, a stalled download could block
  every later `checkForUpdate()` until the app restarted.

### Fixed (found in release testing)

- **App bundles:** `flutter_ota release android --kind aab` failed because the overlay shipped a
  stripped engine. The overlay now ships the unstripped engine (the Android Gradle plugin strips
  it, so the app does not grow), and the release check compares the engine's ELF build ID.
- **Other ABIs:** `release android` refuses a build that also contains native libraries for
  non-arm64 ABIs (Google Play would offer it to devices where it cannot start) and prints the
  `abiFilters` fix.
- **Low-memory verifier kills:** when Android kills the separate verifier process for low memory,
  the SDK reports `EVICTED` and retries later (at most 3 times per patch) instead of blocklisting
  a good patch.
- **Malformed input refused cleanly:** malformed certificates, revocation lists and very deeply
  nested JSON are now refused with a normal rejection (SDK) or `422` (server), instead of an
  exception or a `500`. None of them bypassed a signature check.
- **Rollback wording:** the CLI and docs now say that devices go back to the patch they ran before
  or to the store code, and never download an older patch again (replay protection); fix forward
  with a new patch.

### Changed

- **Breaking:** the Flutter SDK is now the package `flutter_ota_system` (still in
  `packages/ota_client`), prepared for pub.dev: import
  `package:flutter_ota_system/flutter_ota_system.dart` and depend on `flutter_ota_system`.
  `OtaConfig.applicationId` (the server application id from `ota app list`) is now required.
  `OtaConfig.storageDir`, `platform` and `arch` were test-only and are removed. Protocol,
  patch-format, signature and native details (`UpdateCheckResponse`, `SignedFields`,
  `SignatureVerifier`, `NativeBootRuntime`, `NativeBootReport`) are no longer exported.
- The SDK's Android Java package and namespace are now `io.github.punitsoni22.flutter_ota_system`
  (was `dev.flutterota.ota_client`, whose domain ownership is unconfirmed). Plugin registration
  is automatic; apps need no change. On-device file locations are unchanged.
- `./flutter-ota-system.sh status` and the demo seed print the demo app's
  `OTA_APPLICATION_ID` for `example_app`.
- **Breaking for some setups (`OtaClient`):** release builds must use `https://` (local `adb reverse` testing
  of release builds over `http://localhost` no longer works). Debug builds pointed at
  `http://<LAN IP>` (phone on Wi-Fi) must use HTTPS or `adb reverse` with `http://localhost`.

## [0.1.0-alpha.1] - 2026-11-11

First public, **experimental** release (an earlier planned `0.1.0-alpha` tag was never created).
This is the **original alpha**: server-signed `mock-v1` and `aot-bidiff-android-v1` patches, the
`OtaClient` API and the Python `ota` CLI. The bytecode architecture is not part of it (see
0.2.0-alpha). Internally tested only; not production-ready. Tested on a Linux development machine and with
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

See [docs/limitations.md](docs/limitations.md) (known issues are listed there now).
Open bugs: KI-8, KI-10, KI-11 (all low priority); KI-3 is an accepted limitation. The KI-1 and KI-4
fixes are covered by automated tests and were checked on one Android phone only. Also: no audit
log, one shared admin key, no rate limiting, no Key Vault/KMS signer, no Azure Blob adapter, no iOS
code patches (iOS not tested), the single-server `deploy/` setup is not verified, and there are no
published load tests.

[Unreleased]: https://github.com/punitsoni22/flutter_ota_system/compare/v0.2.0-alpha...HEAD
[0.2.0-alpha]: https://github.com/punitsoni22/flutter_ota_system/compare/v0.1.0-alpha.1...v0.2.0-alpha
[0.1.0-alpha.1]: https://github.com/punitsoni22/flutter_ota_system/releases/tag/v0.1.0-alpha.1
