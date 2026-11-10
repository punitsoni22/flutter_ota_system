# Contributing to Punit

Thanks for your interest. Punit is an experimental alpha. Bug reports, tests, documentation and
careful fixes are the most useful contributions right now.

**Security issues:** never in public issues or PRs. See [SECURITY.md](SECURITY.md).

## Ground rules

- Be kind and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Open an issue before large changes (new patch formats, protocol changes, new storage or
  signing backends) so we can agree on the design. Architecture decisions live in `docs/adr/`.
- Changes to the signed message (ADR-0002), rollout bucketing or update-check rules must update
  **both** the backend and `ota_client`, with tests on both sides.
- Never commit secrets, real keys, `.env` files, internal URLs or personal data. CI runs
  gitleaks, and a PR that adds a secret will be closed. The secret then counts as exposed and
  must be rotated.
- By contributing, you agree your contribution is licensed under the Apache License 2.0
  (section 5 of [LICENSE](LICENSE)). Only submit code you have the right to submit, and say so
  if any of it is copied from another project (with its licence).

## Development setup

```bash
cp .env.example .env
./scripts/setup_local.sh && ./scripts/seed_demo.sh && ./scripts/publish_test_patch.sh
./scripts/verify_demo.sh
```

### Backend

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt ruff
.venv/bin/python -m pytest -q
.venv/bin/ruff check --select E,F,W --ignore E501 app tests
```

Tests use SQLite and a temporary directory, so they don't need Docker. Schema changes need an
Alembic migration in `backend/migrations/versions/`.

### Flutter client

```bash
cd packages/ota_client && flutter pub get && flutter analyze && flutter test
cd ../../example_app && flutter pub get && flutter analyze
```

### CLI

```bash
python3 -m venv .venv && .venv/bin/pip install -r cli/requirements.txt
.venv/bin/python cli/ota.py --help
```

## Pull requests

1. Fork, then branch from `main`.
2. Keep PRs focused. Use [Conventional Commits](https://www.conventionalcommits.org/) for
   titles (`fix(backend): ...`, `feat(ota_client): ...`, `docs: ...`).
3. Add or update tests. Run the checks above and `./scripts/verify_demo.sh`.
4. Update docs and `CHANGELOG.md` (Unreleased) when behaviour changes.
5. Fill in the PR template, including the security-impact section.

## Reporting bugs and requesting features

Use the issue forms. Include versions, reproduction steps and logs, **with secrets removed**.
