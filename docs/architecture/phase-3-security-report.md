# Phase 3 report: security hardening of the bytecode patch engine

**Status:** security research with an isolated prototype. Not production code.

| Item | Location |
|---|---|
| Prototype | [prototypes/security_hardening/](../../prototypes/security_hardening/) |
| Threat model | [phase-3-threat-model.md](phase-3-threat-model.md) |
| Validation architecture | [bytecode-validation-architecture.md](bytecode-validation-architecture.md) |
| Test matrix | [phase-3-security-test-matrix.md](phase-3-security-test-matrix.md) |
| Decision record | [ADR 0001](adr/0001-bytecode-engine-and-developer-experience.md) |
| Phase 2 report | [phase-2-compatibility-report.md](phase-2-compatibility-report.md) |

## 1. Summary

Phase 3 adds a verification layer between a patch file and the Dart VM, and a build-time guard
in front of the compiler. It reuses the Phase 1/2 engine and toolchain unchanged.

**Secured (measured):**

- **Authenticity and integrity:** every patch is checked before it can reach a module loader:
  - a canonical signed manifest (ES256, domain-separated, with trusted and revocable key ids);
  - the module SHA-256 and size;
  - binding to the app, the store release, the installed `libapp.so`, the engine/Dart/Flutter
    versions and the dynamic-interface hash;
  - replay protection (sequence), expiry, a blacklist and signed revocation lists.
- **Malformed modules no longer crash the app.** A new module is first loaded in a separate
  Android process (`:otaverify`). Malformed modules that make the VM abort kill only that process:
  - 47 of 53 signed malformed modules were refused this way;
  - the app survived all 65 corpus files.
- **FFI and dynamic calls are refused before bytecode generation** by `patch_guard`, a Dart-aware
  analyzer tool. It covers direct, transitive, conditional, re-exported, aliased and generated FFI
  (18/18 fixtures). The upstream validator misses every FFI case.
- **Activation is atomic, and the last known-good state survives:**
  - a killed activation, a torn stored file, a revoked patch, or a crash before or after the first
    frame each restore the previous confirmed patch;
  - no crash loop was observed.

**Still unsafe (measured):**

- **Invalid instructions in a correctly signed module are not detected before activation.**
  - Two modules with changed opcode bytes passed the isolated load, because the VM does not
    verify instructions and the smoke test does not run those functions.
  - Activated, such a module can crash the app when that code runs; the crash guard rolls back
    after at most 2 failed starts.
  - Success criteria 7 and 8 are therefore **not fully met** (section 5).
- **State-dependent bugs pass verification.** One crashed the app twice before rollback, as
  designed.
- **Key and administration risks are documented, not solved:** a stolen key, a single shared
  admin key, no rotation.

No production code was changed. One Android 13 arm64 phone; not production ready; no Google
Play approval is claimed.

## 2. Existing vulnerabilities and root causes (from Phase 2 and the audit)

| # | Issue | Root cause (pinned source) |
|---|---|---|
| V1 | FFI module passes validation, then aborts the process | `dart2bytecode --validate` checks the dynamic interface only; the interpreter cannot execute FFI and reaches `UNREACHABLE` in `runtime_entry.cc` |
| V2 | Malformed module aborts the process | `bytecode_reader.cc`: `FATAL`/`UNREACHABLE` on malformed input, `ASSERT`s off in release, no validate-only API, instructions never verified |
| V3 | Allowed dynamic calls can return wrong values | Dynamic dispatch to host members that are not `dynamically-callable` is not checked at run time (Phase 2: wrong integer, 3 runs) |
| V4 | Phase 1/2 prototype accepted unsigned patches | Integrity and identity checks only (prototype) |
| V5 | Production protocol v1 does not sign patch id, rollback targets or revocations | [signing-key-management.md](../signing-key-management.md) (documented limitation) |

## 3. What was implemented (prototype only)

| Component | What it does |
|---|---|
| `packages/patch_security` (pure Dart) | Container v2, canonical JSON, manifest schema (no unknown fields), ES256 with domain separation, the 10-step ordered pipeline, signed revocation lists. The same code runs on the phone and in the Linux tests |
| `tools/sign_patch.py` | Prototype signer and key generator (Python `cryptography`, as the backend). Keys are created only in the lab directory, never in the repository |
| `tools/patch_guard` | Build-time guard: directive graph over every conditional configuration, plus resolved-AST checks for FFI elements, dynamic invocation, `noSuchMethod`, `dart:mirrors` and internal libraries. Exit 4 = refused before `dart2bytecode` runs |
| Host overlay (`host_overlay/`) | Secure runtime: staged atomic activation, previous-patch fallback, re-verification at every start, failure counter and blacklist, `ApplicationExitInfo`, live fallback. Android `VerifierService` in `:otaverify` with its own FlutterEngine; `libapp.so` hashed natively. No unsigned module loading |
| Scripts | Host build, patch build (guard → compile → sign), malformed corpus, device suite, guard tests, mutation tests |
| Phase 2 change | `make_module.sh` gained an optional `GUARD` hook; it is off by default, so Phase 2 behaviour is unchanged |

The canonical manifest v2 is designed for the future production protocol (section 10). The
production signing protocol was not changed.

## 4. Signature and integrity verification (Part 3)

| Check | Linux | Phone |
|---|---|---|
| Invalid signature, modified manifest, modified bytecode | rejected | rejected (`bad_signature`, `bad_hash`); previous patch kept |
| Wrong key (trusted id, other key), unknown key, revoked key | rejected | rejected |
| Wrong app, release, `libapp.so`, engine, format, size | rejected | wrong baseline and engine rejected; others in unit tests and corpus |
| Missing or truncated module, partial download | rejected | rejected (`wrong_size`) |
| Replay, expiry, revocation, blacklist | rejected | rejected; signed revocation restored the previous patch |
| Unknown fields, duplicate keys, non-canonical JSON, oversized input | rejected | – |

The module loader is called only after steps 1–10 and the isolated load. The code path is in
`host_overlay/lib/patch_runtime.dart`; the earlier unsigned probe runner was removed from the
Phase 3 host.

## 5. Malformed bytecode (Part 4): the central result

**Reproduction:** the Phase 2 crash was reproduced on the phone in the isolated process. A
signed, truncated module made `:otaverify` abort with SIGABRT, recorded as `CRASHED_NATIVE`.

**Options evaluated:** see [bytecode-validation-architecture.md](bytecode-validation-architecture.md#options-considered-part-4).
The VM has no validation API (option B). An own structural parser (option A) would not cover
references or instructions without re-implementing the VM. The **separate-process load
(option C)** was implemented.

**Device results (65 corpus files, all through the real pipeline, verify-only):**

- **App process:** the same pid from start to end; nothing activated.
- **Crypto and compatibility negatives:** 9 rejected before any load.
- **Signed malformed modules (53):**
  - 46 crashed the verifier, 2 were cleanly rejected, 4 harmless ones were accepted;
  - **2 with changed instruction bytes were accepted**.
- **Install path:** a signed malformed module, an aborting entry point, a throwing entry point and
  a signed FFI module were each refused and blacklisted, and the previous patch kept running.

**Answer to the Part 15 rule:**

- **Criterion 7, "Malformed bytecode cannot crash the main application":** met for every
  structural and reference error, and for any crash at load or initialisation. **Not met** for
  invalid instructions in code the verifier does not run.
- **Criterion 8, "A validly signed but malformed module is safely rejected":** met for 47 of 53;
  **not met** for the instruction case.

**Phase 3 is therefore not declared successful on criteria 7 and 8.**

- **Exact blocker:** the Dart VM's bytecode reader does not verify instructions. The interpreter
  trusts them, and malformed instructions abort the process when executed. There is no supported
  API to verify a module without loading it in the process that would run it.
- **Alternatives:**
  1. **An instruction verifier in the engine's bytecode reader:** check operands, constant-pool
     indexes and jump targets at load time. This is an engine change to maintain for each Flutter
     version, and upstream acceptance is uncertain. It is the only complete fix.
  2. **Exclusive, reproducible compilation:** only the pinned toolchain produces signed modules;
     the server recompiles from source and requires the same hash before signing. Malformed
     instructions could then come only from a compiler bug or a signer compromise, not from
     tampering. Strongly recommended in any case.
  3. **Wider pre-activation execution:** run the module in the verifier, or in CI on the pinned
     runtime, with a test suite that exercises the patched code (coverage gate). This reduces the
     risk but cannot prove it absent.
  4. **Keep the crash guard** as the backstop (verified: at most 2 failed starts, previous patch
     restored).
  5. **Harden the verifier process** with `android:isolatedProcess` (no app files or permissions;
     the module is passed over a file descriptor).

## 6. FFI detection (Part 5)

`patch_guard`:

- walks import, export and part edges, and **every** conditional configuration, from the module's
  entry package, as `dart2bytecode` would;
- checks the resolved AST for every element from `dart:ffi`, including re-exports, import prefixes
  and aliases, and `@Native`.

| Case | Guard | Upstream validator |
|---|---|---|
| Direct import, alias, generated ffigen-style `@Native` file | rejected | compiles |
| Transitive (`case -> feature_catalog -> product_service -> native_crypto`) | rejected, chain shown | (fixture name collision) |
| Conditional import (`if (dart.library.ffi)`) | rejected ("reached through a conditional import") | compiles |
| Re-export inside the module; FFI API re-exported by a host package | rejected | compiles |
| FFI only inside an unchanged host package (runs AOT) | accepted with a warning | compiles |
| `dart:ffi` in comments and string literals | accepted (no false positive) | compiles |
| Real pipeline (`patch_ffi`) | exit 4, no bytecode produced: `patch_ffi -> feature_catalog -> product_service -> dart:ffi` | – |

The Flutter framework itself contains `dart:ffi` imports (desktop window back-ends), so "reject
anything that reaches FFI" would refuse every patch. The rule is: **reject FFI in code compiled
into the module**, and report FFI that only runs AOT in host packages. Calling such a host package
from a module was not tested on the phone (design argument only).

## 7. Dynamic calls (Part 6)

**What the engine does:**

- The upstream validator refuses dynamic calls by default (`dynamicCallsAreDisallowedByDefault`).
- Opt-in needs `--allow-dynamic-calls-in-dynamic-modules` plus a selector allow-list; neither is
  used in Phase 3.
- Flutter framework code compiled AOT is unaffected: the rule concerns module code only.

**What `patch_guard` refuses (resolved static types):**

- dynamic method, getter and setter calls;
- dynamic index (`[]`) and operator calls;
- calls of values typed `dynamic` or `Function`;
- `noSuchMethod` overrides (the upstream validator **accepts** these);
- `dart:mirrors` (unavailable in Flutter).

**What it allows:**

- `dynamic` used only as a type (for example `Map<String, dynamic>`);
- `Object` members (`toString`, `==`, `hashCode`);
- iterating or spreading a `dynamic` value (the compiler inserts an implicit cast; the upstream
  validator agrees);
- `Function.apply` on a statically known function;
- ordinary virtual dispatch.

The upstream validator was used as ground truth for every fixture.

## 8. Package security policy (Part 7)

The Phase 2 classification (PATCHABLE / PATCHABLE_WITH_RESTRICTIONS / NOT_PATCHABLE /
REQUIRES_FULL_RELEASE) is enforced at three points:

- **Build time:**
  - `pkg_rename`: host-owned packages, stale dependency closure, FFI and web-only packages;
  - `patch_guard`: FFI, dynamic calls, mirrors and internal libraries.
- **Signing:** the manifest records every copied package and version, the host packages used, and
  the interface hash.
- **Device:**
  - refuses host-owned packages in a manifest, unrenamed packages, host packages missing from this
    build, and another interface;
  - the isolated load resolves every reference against the real host and type-checks the slots.

Phase 2 architecture is kept: host-owned contracts and state, feature slots, cumulative patches,
one active patch per release (plus one kept previous patch for fallback), no module chaining.

## 9. Signing keys and trust (Part 9)

| Credential | Who holds it | Can do | Compromise means |
|---|---|---|---|
| Patch-signing private key | Today: the server (`LocalSigner`). Proposed: the developer/CI or an offline signer | Sign patches devices accept | Malicious patches for every app trusting it (with control of the update channel) |
| Public verification keys | Compiled into each store build | Verify | Nothing (public) |
| OTA admin API key | Operators | Upload; today this also triggers signing | Today: equal to a key compromise |
| Device registration token | Devices | Report and fetch | Limited to device data |
| Patch signature | In the artifact | Proves who signed | – |

**Recommendations (not implemented; no production change was made):**

1. **Separate uploading from signing.**
   - Patches are signed by the developer's CI or a release manager, with keys the server never
     holds.
   - The server stores and serves, and checks the signature on upload.
2. **Two-level keys.**
   - An offline root key, compiled in, signs short-lived patch-signing keys (key certificates
     carried with the patch).
   - Rotation and revocation then need no store release.
   - Keep a separate key per application and per environment (development/production).
3. **Signed revocation lists with a sequence.** Verified in the prototype.
4. **Approvals and an audit log** for production channels.
5. **Self-hosted only.** No dependency on any service run by the project.

## 10. Production integration requirements

These need the owner's approval before any production change:

- **Protocol v2 (backend and SDK):**
  - the canonical manifest of section 3, signing patch id, sequence, release and `libapp.so`
    binding, runtime and interface hash;
  - the signed revocation list;
  - device-side state (sequence, blacklist, previous patch).
- **SDK (Android):**
  - the isolated verifier service (consider `isolatedProcess`);
  - atomic staging;
  - re-verification at every start;
  - crash guard with `ApplicationExitInfo`, plus a fallback for API < 30;
  - native `libapp.so` hashing.
- **CLI / patch generator:**
  - `pkg_rename` + `patch_guard` + pinned `dart2bytecode`;
  - reproducible builds;
  - strip absolute source paths from modules (Phase 2 finding).
- **Backend:** key separation (section 9), audit log, approvals.

## 11. Fuzz and mutation testing (Part 10)

All fuzzing ran on Linux in the plain Dart VM; no fuzz input reached the app process.

| Fuzz target | Cases | Result |
|---|---|---|
| Container bytes (flips, truncation, appends, length fields, windows, random) | 20 000 | All rejected with a typed reason; none accepted |
| Manifest fields, re-signed with the trusted key | 3 000 | Only genuinely valid manifests accepted (10, each checked) |
| Canonical JSON parser | 20 000 | No crash; no random string was accepted |
| Revocation lists | 3 000 | All rejected |
| Malformed bytecode | 53 | On the device, through the isolated process (section 5) |

**Mutation testing:** 20 protections were disabled one at a time, in temporary copies (15 in
`patch_security`, 5 in `patch_guard`). Each was caught by at least one failing test (**20/20
killed**). One mutation had to be corrected and re-run: Dart parses `false && a || b` as
`(false && a) || b`, so the first version left half of the check active. The repository code was
never modified.

**Coverage limits:**

- no fuzzing of `patch_guard` with random package graphs;
- no coverage-guided fuzzer;
- bytecode fuzzing is limited to the 53-case corpus (20 seeded random mutations).

## 12. Real-device results (Part 12)

On the device, the suites recorded:

- **Install and crash suites:** 26 PASS, 1 FAIL, 1 NOT_TESTED. The FAIL is the partial download:
  it was correctly rejected, but with `wrong_size` where the test expected `truncated`. The
  NOT_TESTED is the device restart.
- **Corpus:** 60 PASS, 7 FAIL. The FAILs are the 6 accepted malformed modules (real findings) and
  the same expected-reason mismatch on A09.
- **New store release over an active patch:** deferred to the final test phase at the owner's
  request; passed in Phase 2 with the earlier runtime.

**Timings:**

- isolated verification of an accepted module: 179–243 ms;
- a crashing module: about 1.1 s;
- first start after install: about 1.6 s to the first frame, because `libapp.so` is hashed once
  and cached; later starts about 0.2 s.

## 13. Success criteria (Part 15)

| # | Criterion | Met? |
|---|---|---|
| 1 | Every patch verified before activation | Yes |
| 2 | Signature and hash verification tested | Yes (Linux and phone) |
| 3 | FFI rejected before bytecode generation | Yes |
| 4 | Transitive and conditional FFI detected | Yes |
| 5 | Dynamic calls remain disabled | Yes |
| 6 | Unsafe dynamic behaviour rejected | Yes |
| 7 | Malformed bytecode cannot crash the main application | **Partly**: structural and load-time errors, yes; invalid instructions on unexecuted paths, **no** |
| 8 | Validly signed malformed module safely rejected | **Partly**: 47/53; the instruction case is not detected |
| 9 | Last known-good state retained | Yes (previous confirmed patch restored) |
| 10 | Crash recovery and rollback tested | Yes (device restart not tested) |
| 11 | Tampering, replay, incompatible releases tested | Yes (new store release not re-run in Phase 3) |
| 12 | Fuzz tests without destabilising the app | Yes |
| 13 | Findings documented with evidence | Yes |
| 14 | Reproducible on Linux | Yes, with the Phase 1 lab (see the prototype README) |
| 15 | Production code untouched | Yes |

**Phase 3 is not declared complete.** Criteria 7 and 8 are blocked by the Dart VM architecture
(section 5). The recommended path is alternatives 1 to 5 together: an engine instruction verifier
if acceptable, otherwise exclusive reproducible compilation, coverage-gated pre-activation tests,
the crash guard and a sandboxed verifier.

## 14. Testing record

Owner's global testing strategy: targeted tests per phase, deep testing once at the end.

**What changed:**

- new `prototypes/security_hardening/`: verification library, guard, signer, host overlay,
  Android verifier service, scripts;
- an optional, default-off `GUARD` hook in `prototypes/real_app_compatibility/scripts/make_module.sh`;
- documentation.

No production code changed.

**Necessary and executed (security-critical changes: all relevant security tests):**

| Area changed | Tests run | Result |
|---|---|---|
| `patch_security` | Unit tests (40) and fuzz tests (4 suites) on Linux | 44/44 PASS |
| `patch_guard` | 18 fixtures with the upstream validator as ground truth; real-pipeline refusals | 18/18 PASS; FFI and dynamic patches refused, no bytecode produced |
| Every security check | Mutation testing in temporary copies | 20/20 killed |
| Host overlay and verifier process | Device install and crash suites; 65-file corpus | See section 12 |
| `make_module.sh` hook | Builds with and without `GUARD` (the default path still produces modules) | PASS |

**Not repeated (unchanged; earlier results referenced):**

- the Phase 1 device suite: 15/15, commit `2a03433`;
- the Phase 2 suites: 46 PASS / 2 FAIL / 1 NOT_TESTED, merged as `1ab291d`; same lab toolchain,
  same phone.

The Phase 2 host app and packages are reused unchanged, apart from the overlay.

**Deferred to the final deep-testing phase:**

- new store release over an active patch with the Phase 3 runtime;
- device restart during activation;
- `patch_guard` fuzzing with random package graphs;
- the "isolation disabled" control build;
- several devices and Flutter versions;
- integration with the production SDK and backend.

**Known risks:**

- invalid instructions in signed modules (section 5);
- state-dependent crashes need up to 2 starts to roll back;
- key-management risks (section 9);
- one device and one engine version only.
