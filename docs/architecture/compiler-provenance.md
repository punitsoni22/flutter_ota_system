# Compiler provenance and reproducible module builds (Phase 3C prototype)

Status: experimental prototype. Android only. Not production code.

## 1. Model

Flutter OTA System keeps a **Shorebird-like local build model**: the developer's machine holds the
pinned toolchain, compiles the patch module locally, and signs it locally. The self-hosted backend
only stores and serves signed files. **There is no remote compilation**: no server ever receives
source code or compiles on a developer's behalf.

The device cannot re-run the compiler, so it needs two things:

1. proof that the module was built by **the toolchain this store build was made for** (provenance);
2. a way for anyone with the same sources and toolchain to rebuild the **same bytes** (reproducibility),
   so a signed module can be audited after the fact.

## 2. Toolchain record

`prototypes/security_hardening/tools/toolchain.py <lab-dir>` computes a record from file **content**,
not from version strings that could be edited:

| Field | Content |
| --- | --- |
| `flutter`, `dart`, `engine`, `dart_revision` | pinned versions (`bytecode_engine/pins.env`) |
| `engine_patch_sha256` | SHA-256 of the Dart VM verifier patch applied to the engine |
| `compiler_sha256` | hash over the sorted (path, SHA-256) list of the pinned `pkg/dart2bytecode` sources |
| `generator_sha256` | same, over our generator tools: package renamer, policy, module builder, security guard, signer |
| `build_config_sha256` | SHA-256 of the engine's GN arguments (`out/android_release_arm64/args.gn`) |
| `bytecode_format` | `kBytecodeFormatVersion` read from the pinned VM headers (3) |
| `id` | SHA-256 of the canonical JSON of all fields above |

- **Host build** (`scripts/build_host.sh`): computes the record, compiles its `id` into the app as
  `OTA_TOOLCHAIN_ID`, and saves the record in the baseline (`baseline.json`, `toolchain.json`).
- **Signer** (`tools/sign_patch.py`): copies the record into every manifest (`toolchain` field, covered
  by the signature).
- **Device** (`package:patch_security`): recomputes the id from the fields (`bad_toolchain` if it does
  not match) and compares it with the compiled-in id (`wrong_toolchain` otherwise).

Tests: Linux unit tests in `packages/patch_security/test/cert_test.dart`, and the signed device
artifacts checked on Linux: a patch with a consistent record for another compiler is refused
(`wrong_toolchain`) and one with a forged id is refused (`bad_toolchain`). The same two cases passed
on an Android 13 arm64 phone (release build, cert suite, 2026-11-12): `wrong_toolchain` and
`bad_toolchain`, and neither file reached the verifier process.

What this proves, honestly: the **signer** declared that the module was built with that toolchain.
It does not prove it cryptographically (the toolchain does not sign its output). Its value is that
(a) an accidental build with another compiler or engine patch is refused, and (b) combined with
reproducibility, an auditor can rebuild the module with the declared toolchain and compare bytes.

## 3. Reproducible builds

Dart bytecode embeds source URIs (for example of framework mixins copied into a module). Before
Phase 3C, modules were compiled under the lab directory in the user's home, so the bytes depended on
the machine and contained the user name.

Phase 3C changes:

- modules are prepared and compiled under a **canonical directory** `MODULES_DIR`
  (default `/tmp/flutter-ota-build`) in all Phase 3 scripts;
- the module's package configuration is rewritten so the SDK, baselines and the pub cache are reached
  through symlinks inside that directory (`.lab`, `.pub-cache`);
- the host's `link.dill` is compiled through the same symlinks, because modules copy source URIs from
  it.

Checks (run on Linux on 2026-11-12: no home path in any of the 15 modules; two builds of
`patch_v1` from different source directories were byte-identical, SHA-256 `5bc4af89…`):

```bash
# no home path in any module
for f in /tmp/flutter-ota-build/*/module.bc; do grep -l -a "/home/" "$f"; done   # prints nothing

# same source, two separate builds -> identical bytes
sha256sum /tmp/flutter-ota-build/<module>/module.bc   # compare between the two builds
```

## 4. Limits

- The canonical directory is a convention: two builds are only byte-identical when they use the same
  `MODULES_DIR`, the same pinned toolchain, the same baseline and the same pub packages.
- Reproducibility was checked on one Linux machine (two builds), not across machines.
- The toolchain record is declared by the signer; a stolen signing key can declare any record. Key
  protection is covered in [signing-and-key-rotation.md](signing-and-key-rotation.md).
