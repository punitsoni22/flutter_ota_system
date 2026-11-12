# Phase 3 final security report (Phase 3C follow-up)

Status: experimental alpha prototype. Android only. Not production-ready. Date: 2026-11-12.

Pinned toolchain (no upgrade): Flutter 3.47.9, Dart 3.13.7, engine `89c39edf`, Dart SDK `416e33b0`.

Device: one Android 13 arm64 phone, release build with the patched engine (baseline
`p3-98657508…`). This report adds to [phase-3-security-report.md](phase-3-security-report.md); it does
not replace it. Raw results: `prototypes/security_hardening/results/device_p3c/`.

## A. Summary

Phase 3 left one blocker open: the Dart VM never verifies bytecode **instructions**, and two validly
signed malformed modules (B25, B27) crashed it. Phase 3C fixes that inside the VM and adds the
remaining hardening items.

| Item | Result |
| --- | --- |
| In-VM bytecode verifier + 12 runtime guards (engine patch) | **Verified on the phone**: B25, B27 and the FFI module refused with a clean error before any of their code ran |
| B25/B27 permanent regression tests | Byte-exact fixtures + corpus entries `R25`/`R27`: **PASS** |
| Android isolated-process verification | **Not achieved**: Flutter cannot start in an isolated process in a release build. Logged fallback to the same-UID separate process (tested) |
| Compiler provenance (toolchain id) and reproducible builds | **Verified** (Linux build + phone rejection of wrong/forged toolchain) |
| Per-app key certificates, rotation, revocation | **Verified on the phone** (10/10). Approvals: Linux only |
| Crash state machine with exit attribution | **Verified on the phone** (9/9; OS eviction not testable without root) |
| Half-download error contract | **Verified on the phone** (`wrong_size` / `truncated`) |

## B. Root cause of B25 and B27

See [phase-3c-vm-investigation.md](phase-3c-vm-investigation.md).

- **B25:** one byte turns `Allocate` into the reserved opcode `Unused20`.
- **B27:** one byte changes a `DirectCall` argument count from 3 to 58.

The reader never checks instructions, and the interpreter trusts every operand.

## C. Bytecode verifier

See [bytecode-verifier.md](bytecode-verifier.md).

- The engine patch is `engine_patch/0001-dart-bytecode-verifier.patch`, applied with `scripts/engine_patch.sh`.
- It verifies every function and closure while the module is read, before any code runs. It checks:
  - opcodes and instruction boundaries;
  - the prologue and registers;
  - branch and handler targets;
  - object-pool kinds and argument counts;
  - field offsets;
  - stack depth.
- 12 interpreter guards cover memory-indexing instructions.

Messages seen on the phone:

```text
R25: Bytecode verification failed in …CatalogFeatureImpl_buildRow: pc 29: reserved opcode …
R27: Bytecode verification failed in …_CatalogScreenState…build: pc 341: DirectCall … (argument count)
FFI: Bytecode verification failed in …ProductService…: pc 15: opcode FfiCall is not allowed in a dynamic module
```

## D. Process isolation

See [verification-process-isolation.md](verification-process-isolation.md).

- The isolated service starts under a separate UID.
- Inside it, Flutter's engine crashes during start-up:
  - SELinux denies the GPU device and SurfaceFlinger;
  - release builds ignore software rendering.
- The crash happens **before** the module is handed over, so it is reported as `UNAVAILABLE`. The app logs `ISOLATION_FALLBACK` and verifies in the Phase 3 `:otaverify` process.
- That process is a separate process, but with the same UID as the app.
- Nothing is called a sandbox.

Real isolation would need a headless Dart embedder. That is out of scope.

## E. Testing record (targeted, Phase 3C only)

Earlier Phase 3 results are unchanged and referenced by commit `066c0cc`.

### Linux

| Test | Result |
| --- | --- |
| `package:patch_security` unit tests (certificates, approvals, toolchain, revocation + Phase 3) | **69/69 pass** |
| Reference verifier: 28 valid modules of Phases 1-3 | all accepted |
| Reference verifier: B25, B27, FFI module | all rejected |
| Engine build with the verifier patch | built (2 min 12 s, peak 7.7 GB) |
| Host build + 30 signed device artifacts + 67-file corpus | all built as expected |
| Python signer -> Dart verifier interop (certified, rotated, approved, plain; 8 negative cases) | all as expected |
| Reproducibility: same module from two source directories | byte-identical (`5bc4af89…`) |
| No `/home/` path in any module | none (a framework-mixin path leak was found and fixed) |

### Phone: corpus, install and certificate suites (96 PASS, 7 FAIL, explained below)

| Group | Result |
| --- | --- |
| Main process alive through all 67 verify-only files (same pid) | PASS |
| `R25`, `R27` refused by the VM verifier, never activated, main loader never called | PASS |
| 9 crypto/compatibility negatives refused before any load; 2 valid controls accepted | PASS |
| 53 malformed `B` files | 49 refused, 4 accepted (see below) |
| Install path: signed patch, cold restarts, upgrade; states DOWNLOADED -> VERIFIED -> PROBATIONARY -> ACTIVE | PASS |
| Half download inside the module -> `wrong_size`; inside the manifest -> `truncated` | PASS |
| Wrong key, untrusted key, wrong baseline, wrong engine, expired, tampered, replay, blacklisted again, revocation, revocation replay, kill during activation, torn stored patch, rollback | PASS |
| Certificate suite: certified patch, other environment, other root, unauthorised rotation, uncertified key, other compiler, forged toolchain id, rotation, old key after root-signed revocation, replayed revocation | 10/10 PASS |

How the 49 refused `B` files break down:
- 9 were refused with a clean error.
- 40 aborted the separate verifier process. These are header or section-level corruptions, where the reader aborts before function verification. The abort is contained and the app stays alive.

The 7 FAIL lines:

| FAIL | Explanation |
| --- | --- |
| `B04`, `B17`, `B32`, `B33` accepted | Harmless changes (truncated last byte, unknown host class, appended bytes, duplicated module). They load and behave exactly like the valid patch. Phase 3 had 6 such cases; B25/B27 are now refused. |
| `p3_isolation` | Isolation not achieved (section D). |
| `p3_neg_malformed_signed`, `p3_neg_ffi_unguarded_signed` | **Harness check bug**, fixed afterwards: the exact-match check did not accept the `isolated_` prefix. The logs show both were refused safely: the FFI module by the VM verifier; the truncated module aborted only the separate process; v2 stayed active. |

### Phone: crash suite (9 PASS, 0 FAIL, 2 NOT_TESTED)

| Case | Result |
| --- | --- |
| Crash before the first frame; crash after the first frame (before confirmation); exception in `build()` | PASS: counted 1/2 then 2/2, blacklisted, previous patch restored, no crash loop |
| Crash after health confirmation | PASS: attributed, SUSPECTED_FAILURE -> ROLLED_BACK -> BLACKLISTED, v2 restored, stable restart |
| Crash after navigation (catalogue opened) | PASS (same checks) |
| Crash during async work after confirmation | PASS (same checks) |
| Force-stop after confirmation; force-stop before confirmation | PASS: not counted |
| Installed APK byte-identical to the baseline APK | PASS |
| OS eviction (SIGKILL from outside) | NOT_TESTED: needs root, not available on the phone. The emulator could not run the harness (Android 16 external-storage ownership) |
| Phone reboot during activation | NOT_TESTED: excluded by the owner |

## F. Compiler provenance and reproducibility

See [compiler-provenance.md](compiler-provenance.md).

- Manifests carry a content-hashed toolchain record, and its id is compiled into the store build.
- Modules are built under the canonical `/tmp/flutter-ota-build`.
- Builds are local only; there is no remote compilation.

## G. Signing and key rotation

See [signing-and-key-rotation.md](signing-and-key-rotation.md).

- Each app has an offline root key that only issues certificates and revocation lists.
- Developer keys are certified per app, per environment and per role.
- The design covers rotation by serial, root-signed revocation, emergency replacement and approvals.

## H. Crash state machine

Implemented in `host_overlay/lib/patch_runtime.dart`.

```text
DOWNLOADED -> VERIFIED -> PROBATIONARY -> ACTIVE
PROBATIONARY/ACTIVE -> SUSPECTED_FAILURE      (crash attributed to a patched session)
SUSPECTED_FAILURE  -> ACTIVE                  (a later session ended without a crash)
SUSPECTED_FAILURE  -> ROLLED_BACK -> BLACKLISTED   (2 attributed failures)
ACTIVE -> ROLLED_BACK (explicit)       DOWNLOADED -> BLACKLISTED (verification failed)
```

How the previous session ended comes from `ApplicationExitInfo`, matched to the session marker by pid:

| Exit | Treated as | Counted? |
| --- | --- | --- |
| Crash, native crash, ANR, initialisation failure, excessive resource use, crash signals, self-exit with an error | crash | counted |
| Force-stop | force-stop | not counted |
| Low memory, freezer, SIGKILL | OS eviction | not counted |
| Normal exit, package update | normal | not counted |

Unknown exits count only for unconfirmed starts.

A safety cap applies: 3 uncounted unconfirmed starts in a row are treated as a failure.

## I. Half-download error contract

| Where the download stops | Error code |
| --- | --- |
| Inside the module | `wrong_size` |
| Inside the header, manifest or signature | `truncated` |

Covered by the unit tests and the two device tests.

## J. Changes made during testing

- The isolated service now reports "module taken". A death before that is `UNAVAILABLE`, which triggers the fallback; previously it was counted as a module crash.
- The suite's half-download expectations now depend on where the file is cut, and its `isolated_` prefix check was fixed.
- Module and `link.dill` builds use canonical symlinks, so no user path leaks into modules.
- On x86_64 emulators the APK must be installed with `--abi arm64-v8a`.

## K. Residual risks and limits

- **Header and section-level corruption** still aborts the reader. 40 corpus files do this. The abort is contained in the separate verifier process, and the main process only loads modules that passed there. Converting these aborts into clean errors needs reader hardening, which is future work.
- **Isolation is not achieved.** The verifier process has the app's UID and can read its files.
- **The verifier is not a type checker.** Type confusion into VM runtime entries remains a residual risk, mitigated by the runtime guards.
- **Valid for the pinned VM and bytecode format 3 only.** A toolchain change needs a review of the verifier's tables.
- **The toolchain record is declared by the signer.** It is not proven. A root key compromise needs a new store release, and prototype keys are files, not hardware.
- **Some tests were not run on a device:**
  - OS eviction and phone reboot were not tested;
  - approvals were tested on Linux only;
  - only one phone model was used.

## L. Phase 3 status

**The malformed-instruction blocker is fixed and verified on a device.** B25 and B27 are refused before activation; the app stays alive; the module loader is never called for them; the previous patch is unchanged.

**Recommendation:** close Phase 3, with the residuals in section K accepted and documented. The isolation goal was not met: it is recorded as a known limitation, not hidden.

Closing Phase 3 needs the owner's approval. Phase 4 has not been started.
