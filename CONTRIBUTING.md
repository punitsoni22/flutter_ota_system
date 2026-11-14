# Contributing to Flutter OTA System

Thanks for your interest. Flutter OTA System is an experimental alpha. Bug reports, tests, documentation and
careful fixes are the most useful contributions right now.

**Security issues:** never in public issues or pull requests. See [SECURITY.md](SECURITY.md).

> [!NOTE]
> **Testing status.** The maintainers develop and test on **Linux** only, and test the app side
> on **Android** only (a small number of devices). iOS, macOS and Windows are **not tested**. If
> you can test one of them, that is a welcome contribution: see
> [Platform Support & Testing Status](docs/limitations.md#compatibility) and the
> [platform testing tasks](docs/roadmap/README.md#platform-testing-planned) in the roadmap.

## Ground rules

- Be kind and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Open an issue before large changes (new patch formats, protocol changes, new storage or
  signing backends) so we can agree on the design. Decisions are recorded in
  [docs/adr/](docs/adr/README.md); planned work is in [docs/roadmap/](docs/roadmap/README.md).
- Changes to the signed message ([ADR-0002](docs/adr/0002-signature-scheme.md)), rollout
  bucketing or update-check rules must update **both** the backend and `ota_client`, with tests on
  both sides.
- Never commit secrets, real keys, `.env` files, internal URLs or personal data. CI runs gitleaks;
  a PR that adds a secret will be closed, and the secret counts as exposed and must be rotated.
- **Licence:** by contributing, you agree that your contribution is licensed under the Apache
  License 2.0 (section 5 of [LICENSE](LICENSE)). Only submit code you have the right to submit.
  If any of it comes from another project, say so in the PR and include its licence and copyright
  notice, and update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- New source files start with:

  ```
  // Copyright 2026 The Punit Authors
  // SPDX-License-Identifier: Apache-2.0
  ```

  (`#` instead of `//` for Python and shell; `<!-- … -->` for HTML.)

## Development environment

| Tool | Version | Needed for |
|---|---|---|
| Git, Bash, curl | recent | everything |
| Python | 3.13 (what CI and the image use) | backend, CLI |
| Docker + Compose v2 | Docker 24+ | local stack, end-to-end test |
| Flutter | **3.47.9** (Dart 3.13.7) for the example app and the bytecode runtime, or 3.50.0 (Dart 3.14.0); the classic `OtaClient` API still allows ≥ 3.44.9 | `ota_client`, its example app, `flutter_ota_cli` |
| Flutter OTA toolchain | downloaded by `flutter_ota toolchain install`, or built locally ([toolchain management](docs/toolchain-management.md)) | release and patch builds, device tests of the bytecode architecture (Linux x64 only) |
| shellcheck | any | shell scripts |

```bash
git clone https://github.com/<your-user>/flutter_ota_system.git
cd flutter_ota_system
./flutter-ota-system.sh setup      # .env, build, dev signing key, start, health checks (safe to re-run)
./flutter-ota-system.sh demo       # seed, publish a test patch, end-to-end checks
```

Repository layout:

```
backend/            FastAPI control plane, Alembic migrations, tests, /admin page
cli/                `ota` admin CLI (and the original alpha Android code-patch tooling)
packages/ota_client Flutter SDK `flutter_ota_system` (Dart + Android Java): FlutterOta + OtaClient
  example/          The official demo app (feature packages: products + freezed, core)
packages/flutter_ota_cli  The `flutter_ota` developer CLI (Dart): toolchain, keys, release, patch
tools/toolchain/    Owner tool: builds the signed toolchain overlay and index
prototypes/         Research prototypes; the engine scripts, verifier patch, pkg_rename, patch_guard
                    and bc_verify used by the toolchain live here (see prototypes/README.md)
docker/, deploy/    nginx config; single-server compose (Caddy)
scripts/            Local setup, demo, verification and pre-publish scripts
docs/               Documentation (start at docs/index.md)
```

How the parts fit: [docs/architecture.md](docs/architecture.md).

## Running the tests

### Backend

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt ruff
.venv/bin/python -m pytest -q                                          # 21 tests, expect: all passed
.venv/bin/ruff check --select E,F,W --ignore E501 app tests ../scripts/demo
```

The tests use SQLite and a temporary directory, so they need no Docker. S3 storage is tested with
`moto`.

### Flutter client and example app

```bash
cd packages/ota_client && flutter pub get && flutter analyze && flutter test   # Flutter 3.47.9; expect: All tests passed!
cd example && flutter pub get && flutter analyze
```

### Developer CLI (`flutter_ota`)

```bash
cd packages/flutter_ota_cli && dart pub get && dart analyze && dart test
```

### Admin CLI (`ota`)

```bash
python3 -m venv .venv && .venv/bin/pip install -r cli/requirements.txt
.venv/bin/python cli/ota.py --help
.venv/bin/python -m py_compile cli/*.py scripts/*.py scripts/demo/*.py
```

CI also checks that an `OTADIF01` diff made by `cli/otadiff.py` rebuilds the original file.

### End to end

```bash
./scripts/verify_demo.sh          # needs the local stack, seeded, with the test patch published
shellcheck -x scripts/*.sh deploy/*.sh
```

Maintainers run `./scripts/prepublish_check.sh` before a release (secret scan, required files,
tests, a fresh end-to-end stack).

## Code style

| Area | Enforced in CI | Also expected |
|---|---|---|
| Python | `ruff check --select E,F,W --ignore E501` | Type hints; small, readable functions |
| Dart | `flutter analyze` with `flutter_lints` | Format with `dart format` |
| Shell | `shellcheck -x` | `set -euo pipefail` (see `scripts/lib.sh`) |
| Secrets | gitleaks | Only obviously fake values in examples |
| Dependencies | Licence gate: no GPL/AGPL in the backend dependency tree | Mention any new dependency and its licence in the PR |

Comments should explain *why*, not *what*. Keep error messages actionable: they are what users
search for in [docs/troubleshooting.md](docs/troubleshooting.md).

## Testing expectations

- Every bug fix comes with a test that fails without the fix, where that is practical.
- Changes to signing, verification, rollout, rollback or the update-check rules need tests on
  **both** the backend (`backend/tests/`) and the client (`packages/ota_client/test/`).
- Schema changes need an Alembic migration in `backend/migrations/versions/`.
- Run `./scripts/verify_demo.sh` for changes that touch the server, storage or the protocol.
- Android code-patch changes cannot be fully tested in CI. Describe how you tested them on a
  device (device, Android version, Flutter version, ABI).
- Say which platform you tested on (host OS, and Android/iOS for app changes). Do not describe a
  platform as supported or tested in the docs unless it was actually tested.

## Reporting bugs

Use the **Bug report** issue form. Include the Flutter OTA System commit, your host OS, Docker/Compose and Flutter versions,
steps to reproduce, and logs (`docker compose logs api`, `verify_demo.sh` output, `adb logcat |
grep -E "OtaBoot|OTA:"`), **with secrets removed**. Check
[docs/troubleshooting.md](docs/troubleshooting.md) first.

## Requesting features

Use the **Feature request** issue form: describe the problem first, then your idea, and say
whether it touches signing, verification, rollout, device auth, the patch format or store policy.
Check [docs/roadmap/](docs/roadmap/README.md) and [docs/limitations.md](docs/limitations.md) to
see whether it is already planned.

## Pull requests

1. Fork the repository and branch from `main`.
2. Keep PRs focused. Use [Conventional Commits](https://www.conventionalcommits.org/) for titles
   (`fix(backend): …`, `feat(ota_client): …`, `docs: …`).
3. Add or update tests and run the checks above.
4. Update the documentation and `CHANGELOG.md` (*Unreleased*) when behaviour changes. Docs must
   describe what the code does; label anything experimental or planned.
5. Fill in the PR template, including the security-impact section.

A maintainer will review it. Expect questions on anything that affects what devices download or
run.
