# Research prototypes

This folder holds **research prototypes** of the proposed bytecode patch engine. They are **not**
demo apps and **not** part of the `flutter_ota_system` package, the backend or the CLI. The
official demo app is [packages/ota_client/example](../packages/ota_client/example/README.md).

> [!WARNING]
> Research code. Not production code, not supported, no store approval claimed. The prototypes
> need a custom Flutter engine build and were tested on Linux (build machine) and one Android 13
> arm64 phone only. Summary:
> [docs/architecture/bytecode-architecture.md](../docs/architecture/bytecode-architecture.md).

| Folder | What it is | Status |
|---|---|---|
| [bytecode_engine/](bytecode_engine/README.md) | Phase 1: pinned toolchain (`pins.env`), engine build scripts and a minimal host app that loads one bytecode patch | Kept: its pinned toolchain and scripts are reused by later phases |
| [real_app_compatibility/](real_app_compatibility/README.md) | Phase 2: a multi-package host app, patch and probe modules, the `pkg_rename` tool and recorded device results | Kept: its packages, patches, scripts and tools are reused by later phases |

Both are kept for reproducibility: every result in the reports can be traced to the scripts and
recorded output here. Their apps exist only to test the engine; do not use them as integration
examples.
