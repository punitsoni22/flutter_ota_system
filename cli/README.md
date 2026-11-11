# flutter-ota-system-cli

The `ota` command-line tool for a self-hosted [Flutter OTA System](../README.md) server: apps, releases,
patches, rollouts and Android code patches. **Experimental (v0.1.0-alpha.1); not published to
PyPI.**

Build and install it locally:

```bash
./scripts/build_cli.sh                     # from the repository root; writes cli/dist/
python3 -m venv ~/.flutter-ota-system-cli
~/.flutter-ota-system-cli/bin/pip install cli/dist/flutter_ota_system_cli-0.1.0a1-py3-none-any.whl
~/.flutter-ota-system-cli/bin/ota --help
```

Commands and options: [docs/cli-reference.md](../docs/cli-reference.md).
