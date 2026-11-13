# Research prototypes

This folder holds the **research prototypes** (Phases 1–3) behind the bytecode architecture. The
product code now lives in `packages/flutter_ota_cli`, `packages/ota_client` and `backend/`; some
prototype pieces are still used by it (the engine build scripts and verifier patch, `pkg_rename`,
`patch_guard`, `bc_verify`, the `dynamic_modules` package). The prototype apps are **not** demo
apps and **not** integration examples. The
official demo app is [packages/ota_client/example](../packages/ota_client/example/README.md).

> [!WARNING]
> Research code. Not production code, not supported, no store approval claimed. The prototypes
> need a custom Flutter engine build and were tested on Linux (build machine) and one Android 13
> arm64 phone only. Current architecture: [docs/architecture.md](../docs/architecture.md).
> The detailed phase reports are kept out of the public documentation (they remain in the Git
> history).

| Folder | What it is | Status |
|---|---|---|
| [bytecode_engine/](bytecode_engine/README.md) | Phase 1: pinned toolchain (`pins.env`), engine build scripts and a minimal host app that loads one bytecode patch | Kept: its pinned toolchain and scripts are reused by later phases |
| [real_app_compatibility/](real_app_compatibility/README.md) | Phase 2: a multi-package host app, patch and probe modules, the `pkg_rename` tool and recorded device results | Kept: its packages, patches, scripts and tools are reused by later phases |
| [security_hardening/](security_hardening/README.md) | Phase 3: patch security (`patch_security`), `patch_guard`, the in-VM bytecode verifier engine patch, `bc_verify`, device security suites | Kept: the guard, verifier patch and `bc_verify` are used by the product toolchain |

Both are kept for reproducibility: every result in the reports can be traced to the scripts and
recorded output here. Their apps exist only to test the engine; do not use them as integration
examples.
