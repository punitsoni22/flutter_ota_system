# Phase 3 prototype: security hardening of the bytecode patch engine

> **Research prototype. Not production code.** It builds on the Phase 1 toolchain
> ([../bytecode_engine/](../bytecode_engine/)) and the Phase 2 host app and packages
> ([../real_app_compatibility/](../real_app_compatibility/)). Tested on Linux and one Android 13
> arm64 phone only. Test signing keys are generated in the lab directory, never in the
> repository.

Current security model: [docs/security.md](../../docs/security.md). Bytecode verifier:
[docs/architecture/bytecode-verifier.md](../../docs/architecture/bytecode-verifier.md). The
Phase 3 reports, threat model and test matrix are kept in the Git history.

## Contents

```text
security_hardening/
├── packages/patch_security/   container v2, canonical manifest, ES256, ordered verification
│   └── test/                  unit tests (Part 3.3 negatives) and bounded fuzz tests
├── tools/
│   ├── sign_patch.py          prototype signer / key generator / revocation lists
│   ├── corpus.py              malformed-bytecode corpus generator (structure-aware + random)
│   └── patch_guard/           build-time FFI / dynamic-call / mirrors guard (+ 18 fixtures)
├── host_overlay/              overlaid on the Phase 2 host app at build time
│   ├── lib/patch_runtime.dart   secure runtime (verification, atomic activation, crash guard)
│   ├── lib/verifier_main.dart   entry point of the isolated verifier
│   ├── lib/main.dart            boot without unsigned module loading
│   └── android/                 MainActivity (exit info, libapp.so hash) + VerifierService (":otaverify")
├── patches/                   crash variants, an FFI patch and a dynamic-call patch
├── scripts/                   build, sign, corpus, device suite, guard tests, mutation tests
└── results/                   recorded text results (no screenshots, local paths removed)
```

## Reproduce

Prerequisite: the Phase 1 lab (engine build and toolchain) as described in
[../bytecode_engine/README.md](../bytecode_engine/README.md). Nothing in it is rebuilt.

```bash
cd prototypes/security_hardening
export LAB=~/.cache/flutter-ota-lab
unset OTA_API_URL
DART=$LAB/flutter/bin/cache/dart-sdk/bin/dart

# 1. Linux: verifier unit + fuzz tests (44 tests).
(cd packages/patch_security && $DART pub get && $DART test)

# 2. Host app + baseline (creates test keys under $LAB/keys/p3 on the first run).
BASE=$(./scripts/build_host.sh | tail -1)

# 3. Guard fixtures (upstream validator as ground truth) and mutation tests.
./scripts/run_guard_tests.sh "$BASE" "$LAB/results/p3/guard"
./scripts/mutation_test.sh "$BASE" "$LAB/results/p3/mutation"

# 4. Signed patches, negatives, crash variants and the malformed corpus.
./scripts/build_device_artifacts.sh "$BASE" "$LAB/work/p3art"

# 5. Phone (USB debugging). The app is installed with `install -r` once; state is reset with the
#    host's test-only RESET_STORE marker.
python3 -I scripts/device_suite_p3.py --baseline "$BASE" --artifacts "$LAB/work/p3art" \
  --results "$LAB/results/p3/device" --suites install,crash,corpus
```

A single patch: `./scripts/make_patch.sh <baseline> <module-dir> <out.otp> <sequence>`. Exit
codes:

- **4:** refused by `patch_guard`; no bytecode was generated.
- **3:** refused by `pkg_rename`.

## Device protocol additions (prototype only)

| Path in the app's external files dir | Meaning |
|---|---|
| `inbox/patch.otp` | signed patch (container v2): verified, isolated-loaded, then activated |
| `inbox/revocations.otp` | signed revocation list |
| `inbox/verify/*.otp` | verify-only requests (security corpus); never activated |
| `inbox/RESET_STORE`, `STORE_TRUNCATE`, `KILL_DURING_ACTIVATION` | test-only hooks |
| `inbox/ROLLBACK` | remove the active and previous patches |

Logcat markers include:

- `ISOLATED_VERIFY status=…`, `REJECTED incoming patch [code]`, `INSTALLED`, `LOADED`, `CONFIRMED`;
- `FAILURE_COUNT`, `BLACKLISTED`, `RESTORED_PREVIOUS`, `STORED_PATCH_INVALID`, `VERIFY_ONLY`.

## Known limits

- **Invalid instructions are not detected.** They are not detected before activation in a
  correctly signed module (see the report, section 5).
- **The test hooks** and the fixed paths are prototype-only.
- **The verifier is not sandboxed.** It runs as a normal `android:process` service, not
  `isolatedProcess`.
