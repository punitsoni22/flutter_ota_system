# punit-cli

The `ota` command-line tool for a self-hosted [Punit](../README.md) server: apps, releases,
patches, rollouts and Android code patches. **Experimental (v0.1.0-alpha); not published to
PyPI.**

Build and install it locally:

```bash
./scripts/build_cli.sh                     # from the repository root; writes cli/dist/
python3 -m venv ~/.punit-cli
~/.punit-cli/bin/pip install cli/dist/punit_cli-0.1.0a0-py3-none-any.whl
~/.punit-cli/bin/ota --help
```

Commands and options: [docs/cli-reference.md](../docs/cli-reference.md).
