# flutter-ota-system-cli

The `ota` admin command-line tool for a self-hosted [Flutter OTA System](../README.md) server:
apps, releases, patches, channels, promotion, rollback and revocation, plus the
[original alpha](../docs/releases-and-patches.md#original-alpha-patch-formats) patch flow.
**Experimental; not published to PyPI.**

App developers using the bytecode architecture use the Dart CLI
[`flutter_ota`](../packages/flutter_ota_cli/README.md) instead; `ota` stays the server-operator tool
(for example `ota patch promote` from staging to production).

Build and install it locally:

```bash
./scripts/build_cli.sh                     # from the repository root; writes cli/dist/
python3 -m venv ~/.flutter-ota-system-cli
~/.flutter-ota-system-cli/bin/pip install cli/dist/flutter_ota_system_cli-0.1.0a1-py3-none-any.whl
~/.flutter-ota-system-cli/bin/ota --help
```

Commands and options: [docs/cli-reference.md](../docs/cli-reference.md).
