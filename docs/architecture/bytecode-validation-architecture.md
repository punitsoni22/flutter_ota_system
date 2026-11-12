# Bytecode validation architecture (Phase 3 prototype)

How a bytecode patch is checked before the app ever runs it, what each check proves, and what it
does **not** prove. This describes the Phase 3 prototype
([prototypes/security_hardening/](../../prototypes/security_hardening/)), not the production SDK.

## Five different properties

| Property | Question | How it is checked | Proves | Does **not** prove |
|---|---|---|---|---|
| **Authenticity** | Who produced this patch? | ES256 signature over the canonical manifest, with a trusted and non-revoked key id | A holder of a trusted key signed exactly this manifest | That the signer is honest, or that the code is safe |
| **Integrity** | Is it the file that was signed? | Module SHA-256 and size from the signed manifest; bounded container parsing; canonical JSON | No byte changed after signing | That the signed bytes were valid bytecode |
| **Structural validity** | Can the Dart VM read it? | **Isolated load** in a separate Android process (`:otaverify`) | The VM read every declaration and every function body without aborting | That the instructions are valid |
| **Runtime compatibility** | Does it fit **this** store build? | Signed app id, release id, `libapp.so` SHA-256 (hashed on the device), runtime versions and interface hash; the isolated load resolves every reference against the real host snapshot; slot type checks | It links against this exact host, and its slots have the host's contract types | That it behaves correctly |
| **Semantic safety** | Will running it crash or misbehave? | **Not verifiable** with this VM. Partly covered by the smoke test in the verifier, the build-time guard and the crash guard | (nothing in general) | Absence of crashes in code paths the smoke test does not run |

**A valid signature is not a safety proof.** A correctly signed module can still contain bytecode
that crashes the interpreter. Phase 3 measured this (section 4).

## What the Dart VM does with a module (pinned source)

Findings from `runtime/lib/object.cc` and `runtime/vm/bytecode_reader.cc` at Dart `416e33b`:

1. **No validate-only step.** `loadDynamicModule` copies the bytes, calls
   `BytecodeLoader::LoadBytecode(load_code = true)` and **immediately invokes the entry point**.
2. **Everything is read at load time.**
   - Every library and class is declared.
   - Every class is put on a pending list.
   - `ReadPendingCode` finalises each class and reads the bytecode of **every** function and field
     initialiser before the entry point runs.
   - Malformed references and sections are therefore detected during the load.
3. **Errors abort the process.**
   - The reader reports a bad magic number or version, and missing libraries, classes, fields or
     functions, with `FATAL` (10 sites) or `UNREACHABLE` (13).
   - Its 127 consistency `ASSERT`s are compiled out in release builds.
   - Only a few conditions are catchable Dart errors, for example "library is already loaded".
4. **Instructions are not verified.** Bytecode instructions are read as data and trusted by the
   interpreter when executed.
5. **No supported validation interface exists** in the engine or the VM.

Consequences:

- loading untrusted bytes in the app's own process is unsafe;
- a load in a **separate process** exercises the full reader without risking the app;
- no load-time check can find invalid instructions.

## Pipeline

```text
build time (developer machine / CI)
  pkg_rename prepare  ->  patch_guard  ->  dart2bytecode (+ upstream validator)  ->  sign (ES256)
                          rejects FFI, dynamic calls, dart:mirrors, internal libraries,
                          noSuchMethod, host-owned packages, stale dependencies

device: new patch (inbox / download)
  1  container bounds (size limits, length fields)
  2  manifest: canonical JSON, schema, no unknown fields
  3  app id, store release, libapp.so SHA-256 (computed natively from the installed APK)
  4  key id trusted and not revoked
  5  ES256 signature (domain-separated)
  6  module SHA-256, 7 module size
  8  package metadata (no host-owned packages, renamed copies, host packages present)
  9  runtime versions, dynamic-interface hash, entry contract
  10 blacklist, revocation list, replay (sequence), expiry
  ---- the module bytes have never been given to a VM up to here ----
  11 ISOLATED LOAD: separate process ":otaverify", own FlutterEngine on the app's own AOT
     snapshot; loads the module, type-checks the slots against the host contracts, smoke-calls
     catalog.version / priceLabel and profile.version / validateName; reports OK / REJECTED;
     if the process dies the app sees CRASHED; if it hangs (20 s) it is killed: TIMEOUT.
     One check per process (modules cannot be unloaded).
  12 only if OK: atomic activation (staging -> active; the previous confirmed patch is kept)

device: every start
  re-run steps 1-10 on the stored patch (reinstall mode: its own sequence is allowed)
  attempt marker -> load in the app -> first frame -> confirm after 3 s
  failure before confirmation (crash, Dart error, build exception) -> counted;
  2 failures -> blacklisted -> previous confirmed patch restored (re-verified) or baseline
```

Any rejection keeps the current state. The active patch is replaced only at step 12.

## Measurements (Android 13 arm64 phone, release build)

| Item | Value |
|---|---|
| Isolated verification, module accepted | 179–243 ms end to end (verifier process start, engine start, load) |
| Isolated verification, module crashed the verifier | about 1.1 s (includes 600 ms waiting for Android's exit record) |
| Corpus, 65 files (verify-only) | median 1.28 s each; the app process survived all 65 |
| First start after install (computes the `libapp.so` hash once and caches it) | about 1.6 s to the first frame (later starts about 0.2 s) |
| Added cost on a normal start | steps 1–10 only (no isolated load) |

## Results of the malformed-bytecode corpus

53 mutations of a real 5.5 KB module, each **validly signed with a trusted key**, plus 12 control
and negative files. All were sent through the full device pipeline in verify-only mode.

| Category | Files | Outcome |
|---|---|---|
| Header (magic, version) | 3 | 3 crashed the verifier |
| Section table (offsets past the end, overlapping, huge counts) | 5 | 5 crashed |
| Missing metadata (no entry point, all sections empty) | 2 | 2 REJECTED (clean Dart error) |
| Truncated | 5 | 4 crashed; **1 accepted** (last byte removed, unused) |
| References (unknown host library, module URI collision) | 2 | 2 crashed |
| Interface metadata (renamed host class/member) | 2 | 1 crashed; **1 accepted** (renamed string not used for resolution) |
| Constant pool / object table | 3 | 3 crashed |
| Corrupted sections (strings, libraries, classes, members) | 4 | 4 crashed |
| Instructions (opcode bytes changed) | 5 | 3 crashed; **2 accepted** (functions not run by the smoke test) |
| Size (appended garbage, module repeated) | 2 | **2 accepted** (the VM ignores trailing bytes) |
| Seeded random mutations | 20 | 20 crashed |
| Signed FFI module (guard bypassed) | 1 | crashed the verifier |
| Crypto/compatibility negatives | 9 | 9 rejected before any load |
| Valid controls | 2 | 2 accepted |

**The app process survived every file. No file was activated.**

Six malformed modules passed the isolated load:

- **4 are harmless.** Their usable content is identical; the VM does not check that the file size
  matches its sections. A cheap structural pre-check (offsets inside the file, and the last
  section ending at the end of the file) would refuse them. It is not implemented, so as not to
  present an unverified parser as a security boundary.
- **2 have changed instruction bytes.** If activated, they could crash the app when the changed
  function first runs. The crash guard then rolls back after at most 2 failed starts. This is the
  **remaining blocker** (see the report, section 5).

## What the isolated load cannot see

- Invalid instructions in functions it does not execute.
- Bugs that depend on app state the verifier does not have. Measured: a crash only when a user is
  signed in passed verification, crashed the app twice, and was rolled back.
- Slow or resource-hungry code outside the smoke test.
- Malicious but well-formed code (that is authenticity and policy, not validation).

## Options considered (Part 4)

| Option | Protects against | Cannot protect against | Cost | Normal devices? | Status |
|---|---|---|---|---|---|
| A. Own static structural verifier | Bad offsets, sizes, counts | Bad references (needs the host), invalid instructions unless it re-implements the VM's reader and an instruction verifier | High; risk of a false sense of security | Yes | Not built (only a size/offset pre-check is recommended) |
| B. VM's own validation | – | Everything: it aborts instead of reporting | – | – | Not available |
| C. Separate validation process (load test) | All load-time structural and reference errors; initialisation crashes; slot type errors | Invalid instructions not executed; state-dependent bugs | About 0.2 s per new patch, about 1.1 s if it crashes | Yes (a standard Android service with `android:process`) | **Implemented, verified on device** |
| D. Android isolated service (`android:isolatedProcess`) | Same as C, plus a sandbox without app permissions or files | Same as C | Same, plus the module must be passed over a file descriptor | Yes | Not built; recommended hardening of C |
| E. Build-time validation with the pinned runtime | Compiler-produced structural errors before release | Tampering after build (covered by signing); runtime-state bugs | One run of the module in a test harness or emulator | n/a (CI) | Recommended (reproducible build + load test in CI) |
| F. Combination | C + D + E + signatures + crash guard | Invalid instructions on rarely run paths | Sum | Yes | **Recommended production design** |

A complete solution for invalid instructions needs **an instruction verifier in the VM's bytecode
reader** (an engine change, so a custom engine patch to maintain), or a guarantee that only the
pinned, reproducible compiler can produce signed modules.
