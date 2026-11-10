# Installation improvements (planned for Step 4)

> **Roadmap status: 🔭 planned.** Nothing on this page is implemented yet. It lists gaps found while
> documenting the current installation ([installation.md](../installation.md),
> [operations.md](../operations.md)).

## Gaps in the current installation

| # | Gap today | Proposed improvement |
|---|---|---|
| 1 | The local quickstart is tested on Linux only | Test on macOS and Windows (Docker Desktop) and document differences |
| 2 | Four commands are needed for a demo (`setup_local.sh`, `seed_demo.sh`, `publish_test_patch.sh`, `verify_demo.sh`) | One command that sets up, seeds and verifies, with clear output |
| 3 | The `ota` CLI needs a manual Python virtual environment, an alias and two environment variables | **Partly done:** `scripts/build_cli.sh` builds a wheel for local install (tested on Linux, Python 3.10 and 3.14). Not on PyPI; public distribution is undecided. The CLI's top-level module names (`ota`, `android`, `otadiff`) should move into one package first |
| 4 | Phones on a LAN need manual `.env` edits (`OTA_CDN_BASE_URL`, `PUNIT_BIND_ADDRESS`) | A helper that detects the LAN IP and prints the exact app `--dart-define`s |
| 5 | The single-server production setup (`deploy/`) has **not been verified end to end** | Test it from a clean server; turn it into a documented, tested "server quickstart" |
| 6 | Production signing-key creation and backup are manual | A guided first-run command, with backup instructions and a check that the key exists |
| 7 | No pre-built images; users build from source | Optionally publish images, **after** the licence duties in [THIRD_PARTY_NOTICES.md §7](../../THIRD_PARTY_NOTICES.md#7-future-actions-before-publishing-pre-built-docker-images) are done |
| 8 | No upgrade guide between versions | Document upgrades (pull, rebuild, migrations run on start) and test a real upgrade |
| 9 | Backup and restore are documented but not tested | Add a tested restore drill |
| 10 | The `example_app` default slug in code is `demo`, while the demo scripts create `punit-demo` | Align the defaults so the app works without `--dart-define=OTA_APP` |
| 11 | `ota_client` is not published on pub.dev; apps use a git or path dependency | Decide on publishing, versioning and tags |
