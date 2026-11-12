# Phase 3C: Dart VM investigation of the two dangerous modules

Status: experimental prototype work. Android only; checked on Linux and on one Android 13 arm64
phone (release build, 2026-11-12, section 5). Not production code.

Pinned toolchain (unchanged, no upgrade): Flutter 3.47.9, Dart 3.13.7, engine `89c39edf`,
Dart SDK revision `416e33b0`.

## 1. The question

The Phase 3 malformed-bytecode corpus found two **validly signed** modules that crashed the Dart
VM when loaded (the separate verifier process contained the crash, but the VM itself was not safe):

| Corpus id | Mutation of `patch_v1` (5 527 bytes) | Where it lands | Effect |
| --- | --- | --- | --- |
| B25 (`25_codes_opcode_1`) | byte 4122: `0x10` -> `0x47` | `CatalogFeatureImpl.buildRow`: `Allocate` becomes the reserved opcode `Unused20` | interpreter reaches an unimplemented opcode, VM aborts |
| B27 (`27_codes_opcode_3`) | byte 5405: `0x03` -> `0x3a` | `_CatalogScreenState.build`: `DirectCall CP#83` argument count 3 -> 58 (`Column` constructor) | interpreter reads 58 "arguments" below the frame, memory corruption, VM aborts |

Hashes: base module `dedf3762…`, B25 `ce9d4c2e…`, B27 `f918fac3…`. Both are kept byte-exact
(only an equal-length redaction of a local path string) in
`prototypes/security_hardening/tools/bc_verify/fixtures/malformed/` as permanent regression tests.

The Phase 3 container signature and hash checks cannot catch these: a correctly signed module from a
compromised or buggy build pipeline has exactly this shape.

## 2. What the pinned VM does at load time

Source read: `runtime/vm/bytecode_reader.cc`, `runtime/vm/interpreter.cc`,
`runtime/vm/constants_kbc.h`, `runtime/lib/dynamic_modules` entry points, and
`pkg/dart2bytecode` (the compiler).

1. `loadDynamicModule` calls `BytecodeLoader::LoadBytecode(load_code=true)` and then **immediately
   invokes the module's entry point**. There is no "validate only" API.
2. The reader checks the container framing (magic `DBC3`, version 3, 14 section offsets/sizes) and
   reads every library, class and member declaration. `ReadPendingCode` reads every function's
   bytecode, object pool and exception table.
3. Checks inside the reader are mostly `ASSERT`s (127 of them in `bytecode_reader.cc`). `ASSERT` is
   compiled out in release builds; the remaining hard checks are `FATAL`/`UNREACHABLE`, which
   **abort the process**.
4. **Instructions are never verified.** The interpreter trusts every operand: register indices,
   argument counts, jump targets (`pc + T`), object-pool indices and the kind of object at each pool
   slot (it casts without checking), field offsets in the pool (`Smi(HostOffset / kCompressedWordSize)`).
5. Opcodes are defined by the X-macro `KERNEL_BYTECODES_LIST`: each has an encoding (`0`, `A`, `D`,
   `X`, `T`, `A_E`, `A_Y`, `D_F`, `A_B_C`, `D_A_B_C`…) and operand meanings (`num`, `lit`, `reg`,
   `xeg`, `tgt`, …). Some codes are reserved (`Unused*`), some VM-internal (`VMInternal_*`) or
   debugger-only (breakpoint variants); `kInstructionSize` gives sizes for the compact and wide forms.

Conclusion: in the pinned VM, **any** instruction-level corruption that survives the signature check
reaches the interpreter. A separate verifier process only limits the blast radius.

## 3. Interpreter frame model (needed for a sound verifier)

Determined from `interpreter.cc` and confirmed on all 28 valid modules of the Phase 1-3 corpus:

- `Entry D` -> frame size `D`.
- `EntryOptional A, B, C` -> frame `A + B + C`; followed by `B` single `LoadConstant` or `C` pairs of
  `LoadConstant` (same register), consumed by the interpreter as default values (checked only by
  `ASSERT` upstream).
- `EntrySuspendable` -> `1 + A + B + C`: slot `FP[0]` is reserved for the suspend state.
- An optional `Frame D` follows the prologue; `Frame` anywhere else is invalid.
- Exception handlers start with `SetFrame`; `Suspend` falls through, and its resume point has one
  more stack slot.
- `UncheckedClosureCall` consumes `F + 1` slots; every call's `F` must equal
  `ArgumentsDescriptor::SizeWithTypeArgs` of its pool argument descriptor.
- Async handlers restore one slot **below** the prologue frame, so stack depths legitimately differ
  where paths merge. An equal-depth rule (JVM style) falsely rejects valid modules; an
  **interval dataflow** `[lo, hi]` per instruction is required.

## 4. Options considered

| Option | Result |
| --- | --- |
| A. Verify on the device in Dart before loading (parse DBC3 ourselves) | Duplicates the reader; any divergence from the VM's parser is a bypass. Rejected as the primary defence. |
| B. Reference verifier on the build machine only | Useful (implemented: `tools/bc_verify`), but the device must not trust the build machine's verdict. |
| C. **Verifier inside the VM, run by the reader on the same parsed objects the interpreter uses** | Chosen. No second parser; runs before any of the module's code; failure is a clean Dart `StateError`. |
| D. Upgrade the Dart SDK | Not allowed (pinned toolchain) and upstream has no instruction verifier either. |

## 5. Result

The engine patch `prototypes/security_hardening/engine_patch/0001-dart-bytecode-verifier.patch`
(base `BASE_DART_REVISION` = `416e33b0…`, applied/reverted by `scripts/engine_patch.sh`) adds:

- `runtime/vm/bytecode_verifier.{h,cc}`: per-function verification (see
  [bytecode-verifier.md](bytecode-verifier.md));
- `bytecode_reader.cc`: call to the verifier for every function and closure right after its
  exception table is read, `Exceptions::ThrowStateError("Bytecode verification failed in …")` on
  failure; two release-mode checks for exception-handler type indices;
- `interpreter.cc`: 12 runtime bounds/type guards on memory-indexing instructions (field, context,
  record and closure element loads/stores) that throw `ArgumentError` instead of corrupting memory;
- `vm_sources.gni`: the two new files.

Build: one engine rebuild (2 min 12 s, peak 7.7 GB, `-j3`, `nice`), installed into the lab toolchain
by `prepare_toolchain.sh`.

Measured on Linux with the reference verifier (same rules): all 28 valid modules accepted; B25,
B27 and the FFI module rejected.

Measured on the device (2026-11-12, Android 13 arm64 phone, release build with the patched engine,
67 signed corpus files, verify-only):

- The main process survived all 67 files (same pid).
- B25 and B27 (`R25`/`R27`) are refused by the in-VM verifier with a clean `StateError`:
  `pc 29: reserved opcode` in `CatalogFeatureImpl_buildRow`, and `pc 341: DirectCall` (wrong
  argument count) in `_CatalogScreenState…build`. They were never activated, the previous patch
  stayed active and the main process never called its loader.
- The signed FFI module (guard bypassed) is refused: `opcode FfiCall is not allowed in a dynamic
  module`.
- Of 53 malformed B-files, 49 were refused: 9 clean rejections, and 40 aborted the separate
  verifier process. Those 40 are header- or section-level corruptions where the reader aborts before
  function verification starts; the abort is contained in the separate process and the app stays
  alive. 4 were accepted but are harmless (B04, B17, B32, B33): they load and behave correctly.
  Phase 3 had 6 accepted; B25 and B27 are now refused.
- The 9 signature/compatibility negatives were refused before any load; the 2 valid controls were
  accepted.

Crash-state-machine results on the device: see
[phase-3-final-security-report.md](phase-3-final-security-report.md).

## 6. Honest limits

- The static verifier checks **structure**, not full types: it cannot prove the runtime class of
  every stack value. Memory-indexing instructions are therefore also guarded at run time (section 5).
  A residual risk remains for type confusion passed into VM runtime entries (for example
  `DRT_InstantiateType` arguments); it is documented as a residual in the final report.
- The verifier covers this pinned VM and bytecode format 3 only; any toolchain change requires
  re-reviewing the opcode table (the toolchain id in each manifest makes such a change explicit).
- The separate verifier process is kept as a second layer for VM defects that the verifier does not
  cover (for example the header-level reader aborts above). It is a same-UID process, not an Android
  isolated process: see [verification-process-isolation.md](verification-process-isolation.md).
