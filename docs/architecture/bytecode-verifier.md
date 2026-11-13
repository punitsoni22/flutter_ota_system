# Bytecode verifier

Status: experimental alpha (part of the Flutter OTA custom engine). Pinned Dart VM only (Dart 3.13.7, revision `416e33b0`, bytecode
format 3). Android only. Not production-ready.

Why it exists: the pinned Dart VM never verifies the instructions of a dynamic module. During
security testing, two validly signed modules with one changed byte each (B25: a reserved opcode;
B27: a wrong argument count) crashed it. The verifier rejects both with a clean error.

## 1. Where it runs

```text
signed patch ──> package:patch_security (signature, hashes, manifest, toolchain id, certificates)
             ──> separate verifier process ──> loadDynamicModule
                                                 └─ BytecodeReader reads each function
                                                      └─ VerifyBytecode(function)   <── this verifier
                                                           ok:   continue reading
                                                           fail: StateError("Bytecode verification failed in …")
             ──> only on OK: main process loads the same bytes (and the verifier runs again there)
```

- On the device: `runtime/vm/bytecode_verifier.cc` in the patched engine
  (`prototypes/security_hardening/engine_patch/0001-dart-bytecode-verifier.patch`). It runs on the
  objects the reader has just built (object pool, exception table, function), so there is no second
  parser that could disagree with the VM.
- It runs for **every** function and closure of the module, **before** the module's entry point or
  any of its code runs. A failure is a normal Dart exception: the verifier process reports
  `REJECTED`, the main process never calls its loader, the active patch is unchanged.
- On the build machine: `prototypes/security_hardening/tools/bc_verify` applies the same rules to a
  module file (reference implementation; it is a build-time check, the device does not trust it).

## 2. What is checked (per function)

| Area | Rule |
| --- | --- |
| Opcodes | Only public opcodes of the pinned `KERNEL_BYTECODES_LIST`. Reserved (`Unused*`), VM-internal and breakpoint opcodes are rejected. `FfiCall`, `ExternalCall`, `Trap` and `RecordCoverage` are not allowed in modules. |
| Boundaries | Every instruction is complete (no truncated instruction at the end); compact and wide encodings decoded with the VM's own size table. |
| Prologue | Function starts with `Entry`, `EntryOptional` or `EntrySuspendable`; the `LoadConstant` shape consumed by `EntryOptional` is exact; `Frame` only in the prologue; `Suspend` only with a suspend-state slot. |
| Registers | Register operands inside the frame; signed (`xeg`) operands inside frame or parameters; `MoveSpecial` index in range. |
| Branches | Every jump target, every try range and every handler start is an instruction boundary inside the function; handlers start with `SetFrame`, and `SetFrame` stays inside the frame. |
| Object pool | Index in range and the **kind** the interpreter casts to: calls -> `Function` (or selector `String` for dynamic calls) **plus an argument descriptor whose size equals the instruction's argument count** (catches B27); static/instance fields -> `Field`, and an instance field's offset slot equals `Field::HostOffset()`; classes, types, type arguments, subtype test caches, record types, closure functions; constants are tagged objects. |
| Stack | Interval dataflow `[lo, hi]` over all paths: no instruction pops below the frame floor, depth bounded (frame + 4096), no path runs past the end of the function. Stack effects come from a fixed table derived from `interpreter.cc`; an opcode without an entry is rejected. |
| Exceptions | Release-mode checks of exception-handler type counts and type indices in the reader. |

B25 fails at "reserved opcode `Unused20`"; B27 fails at "argument descriptor size does not match
the argument count".

## 3. Runtime guards (second line)

The static rules do not prove the class of every stack value. The patch therefore also adds 12
checks in `interpreter.cc` to the instructions that index memory (`LoadFieldTOS`, `StoreFieldTOS`,
`LoadContextVar`, `StoreContextVar`, `LoadContextParent`, `StoreContextParent`,
`LoadTypeArgumentsField`, `LoadRecordField`, `LoadClosureElement`, `StoreClosureElement`,
`StoreIndexedTOS`, `InitLateField`). On a wrong receiver class or an offset out of bounds they throw
`ArgumentError` instead of reading or writing outside the object.

## 4. Tests

| Test | Where | Result |
| --- | --- | --- |
| 28 valid modules accepted (Phase 1-3 patches and probes) | Linux, reference verifier | passed |
| B25, B27 and the FFI module rejected (fixtures kept in `tools/bc_verify/fixtures`) | Linux, reference verifier | passed |
| B25/B27 signed, refused on the device by the VM verifier (`R25`/`R27` in the corpus, permanent) | Android 13 arm64 phone, release build | **passed**: clean `StateError` (`pc 29: reserved opcode` in `CatalogFeatureImpl_buildRow`; `pc 341: DirectCall` argument count in `_CatalogScreenState…build`); never activated, previous patch unchanged, main loader never called |
| Signed FFI module (guard bypassed) refused by the VM verifier | Android 13 arm64 phone, release build | **passed**: `opcode FfiCall is not allowed in a dynamic module` |
| Whole corpus (67 signed files, verify-only): main process alive | Android 13 arm64 phone, release build | **passed**: same main process (same pid) after all 67 files; details below |

Device corpus results (2026-11-12, verify-only):

- 53 malformed B-files: 49 refused. 9 were clean rejections. 40 aborted the separate verifier
  process: these are header- or section-level corruptions where the reader aborts before function
  verification starts. The abort stayed in the separate process and the app stayed alive.
- 4 malformed files were accepted but are harmless: B04 (last byte cut off), B17 (unknown host
  class), B32 (garbage appended) and B33 (module duplicated). They load and behave correctly (the
  smoke test prints its normal output). Phase 3 had 6 accepted files; B25 and B27 are now refused.
- 9 signature/compatibility negatives were refused before any load; the 2 valid controls were
  accepted.
- So the verifier fixes the instruction-level cases (B25, B27, FFI). Header- and section-level
  corruptions still abort the reader; this is contained by the separate process, not fixed.

Run the Linux check:

```bash
# DART_SRC = the pinned Dart SDK checkout of the lab engine (pkg/dart2bytecode supplies the tables)
DART_SRC=~/.cache/flutter-ota-lab/engine/engine/src/flutter/third_party/dart
cd prototypes/security_hardening/tools/bc_verify
dart --packages=$DART_SRC/.dart_tool/package_config.json bin/bc_verify.dart fixtures/valid/*.bc      # every file: OK
dart --packages=$DART_SRC/.dart_tool/package_config.json bin/bc_verify.dart fixtures/malformed/*.bc  # every file: REJECT
```

## 5. Limits

- Not a type checker: residual risk of type confusion into VM runtime entries (for example
  instantiating a type with a wrong argument). Mitigated by the signature, the separate verifier process and
  the runtime guards, not eliminated.
- Valid only for the pinned VM and bytecode format 3. A toolchain change needs a review of the
  opcode table and stack-effect table; the manifest's toolchain id makes such a change visible.
- The verifier adds load time; it was not optimised. On the test phone, verifying a small demo patch in the separate process took 295 ms (in the background).
