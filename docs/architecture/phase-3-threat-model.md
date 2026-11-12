# Phase 3 threat model: bytecode patch engine

**Scope:** the Phase 3 security prototype
([prototypes/security_hardening/](../../prototypes/security_hardening/)), built on the Phase 1/2
bytecode engine (Flutter 3.47.9, engine `89c39edf`, Dart 3.13.7, Android arm64). It is not the
production system. Evidence: [phase-3-security-report.md](phase-3-security-report.md) and
[phase-3-security-test-matrix.md](phase-3-security-test-matrix.md).

**Assets protected:**

- the integrity of the code the app runs;
- the app's availability (no crash, no crash loop);
- the last known-good state;
- the signing keys.

**Trust anchors on the device:**

- the public keys compiled into the store build;
- the installed APK, from which `libapp.so` is hashed on the device.

Labels used below: **Verified** (tested in Phase 3), **Design** (argued, not tested),
**Open** (not solved).

## Summary

| # | Threat | Residual risk after Phase 3 |
|---|---|---|
| T1 | Network attacker modifies a patch | Low |
| T2 | Corruption in storage or during download | Low |
| T3 | Compromised storage credentials (artifact bucket) | Low |
| T4 | Malicious patch uploaded by an administrator | **High** (organisational) |
| T5 | Compromised signing key | **High until rotation exists** |
| T6 | Buggy bytecode compiler | **Medium** (see T6) |
| T7 | Malicious third-party Dart dependency | **High** (unsolved, as for any app) |
| T8 | Replay of an old patch | Low |
| T9 | Wrong application or release receives a patch | Low |
| T10 | Corrupted local patch metadata | Low |
| T11 | App crash during patch activation | Low (crash guard), Medium for malformed instructions |
| T12 | Valid signature on malformed bytecode | **Medium; open blocker** |
| T13 | FFI or dynamic calls in a module | Low (build-time guard) |

## Threats

### T1. Network attacker modifies a patch

- **Scenario:** an attacker on the path (or a broken TLS setup) changes the patch file or the
  update-check response.
- **Existing (production, v0.1.0-alpha.1):** HTTPS; ES256 over a canonical message; SHA-256 and
  size of the download ([signing-key-management.md](../signing-key-management.md)).
- **Missing:** in protocol v1, the patch id, rollback targets and revocations are not signed.
- **Mitigation (prototype):**
  - the container v2 signs one canonical manifest, which binds the app id, store release, the
    `libapp.so` SHA-256, the patch id, the sequence, runtime versions, the interface hash and the
    module SHA-256 and size;
  - domain-separated signatures;
  - signed revocation lists.
- **Verification:** **Verified.** Unit tests cover tampering of the manifest, module, signature
  and length fields, and 20 000 fuzzed containers. On the phone, a tampered module and a tampered
  manifest were rejected, and the app stayed on its previous patch.
- **Residual:** low. Requires breaking ES256.

### T2. Corruption in storage or during download

- **Scenario:** a truncated download, a bit flip, or a torn write of the stored patch.
- **Existing:** size and SHA-256 checks; atomic `tmp` + rename.
- **Mitigation:**
  - bounded parsing with size limits;
  - staging, then rename, then state update, each with fsync;
  - leftovers are removed at start-up;
  - the stored patch is re-verified at every start;
  - the previous confirmed patch is restored if the active one fails.
- **Verification:** **Verified** on the phone: a partial download, a stored patch truncated on
  disk, and the process killed between staging and activation.
- **Residual:** low. A device restart during activation was not tested (it would reboot the
  owner's phone); the design relies on fsync and rename.

### T3. Compromised storage credentials

- **Scenario:** an attacker can write to the artifact store (S3/R2/MinIO).
- **Existing:** the device verifies the signature, and signatures are made by the server's key,
  not stored with the file.
- **Mitigation:** container v2 signatures cover everything the device uses.
- **Verification:** **Verified** indirectly (modified files are rejected, see T1).
- **Residual:** low for integrity. The attacker can still delete files (availability).

### T4. Malicious patch uploaded by an administrator

- **Scenario:** an admin, or a stolen admin API key, uploads harmful but correctly built Dart code.
  The server signs every upload ([signing-key-management.md](../signing-key-management.md)).
- **Existing:** none beyond authentication (one shared admin key).
- **Missing:** separation between uploading and signing, approvals, audit log, per-app keys.
- **Mitigation (proposal):**
  - developer-side signing: the CI or a release manager signs, and the server never holds the key;
  - two-person approval for production channels;
  - an audit log;
  - signed revocation lists to recall a patch.
- **Verification:** **Design**. Signed revocation was **Verified** on the phone (the active patch
  was revoked, and the previous one restored).
- **Residual:** **high**. A signature proves who signed, not that the code is benign.

### T5. Compromised signing key

- **Scenario:** the private key is stolen.
- **Existing:** several trusted key ids can be compiled in; no rotation tooling.
- **Mitigation (prototype):**
  - key ids are bound into the manifest;
  - a signed revocation list can revoke key ids, and patches signed by a revoked key are then
    refused.
- **Proposal:** a two-level scheme. A root key, kept offline, signs short-lived patch-signing keys
  (see the report, section 9). Rotation would then need no new store build.
- **Verification:** **Verified** in unit tests (revoked key refused). The revocation list was
  **Verified** on the phone. Rotation is **Open**.
- **Residual:** **high** until rotation exists. Today a stolen key, plus control of the update
  channel, can sign patches for every app that trusts it. Revocation itself relies on the same key
  set.

### T6. Buggy bytecode compiler

- **Scenario:** `dart2bytecode` emits bytecode that is invalid, or that differs from the source.
- **Existing:** none (Phase 2 used the upstream compiler as is).
- **Mitigation:**
  - patches are compiled only by a pinned, hash-checked toolchain;
  - the isolated load rejects structurally invalid output;
  - the crash guard limits runtime damage.
- **Proposal:** reproducible builds, with the server recompiling from source and comparing hashes.
- **Verification:** **Verified** that structural errors are caught in isolation. Invalid
  instructions are **not** caught (T12).
- **Residual:** medium.

### T7. Malicious third-party Dart dependency

- **Scenario:** a pure-Dart package update in a patch contains harmful code.
- **Existing:** none.
- **Mitigation:**
  - `patch_guard` refuses FFI, `dart:mirrors`, internal libraries and dynamic calls;
  - the manifest lists every copied package and version;
  - the dependency closure is enforced by `pkg_rename`.
- **Verification:** **Verified** for the refused constructs (18/18 fixtures, and in the real
  pipeline).
- **Residual:** **high**. Malicious but well-formed Dart code is not detectable by these checks.
  The same holds for a store release.

### T8. Replay of an old patch

- **Scenario:** an older, validly signed patch is delivered again (for example one with a known
  bug).
- **Existing:** in v1, a client-side anti-replay check with a server-named exception.
- **Mitigation:**
  - a monotonic `sequence` per release, stored on the device;
  - only the active patch may be re-verified with its own sequence;
  - revocation lists carry their own sequence.
- **Verification:** **Verified** on the phone (v1 refused while v2 was active; a revocation list
  replay was refused) and in unit tests.
- **Residual:** low. Rolling forward to old content requires a new, higher sequence.

### T9. Wrong application or release receives a patch

- **Scenario:** a patch for another app, another store build, or another engine.
- **Mitigation:**
  - app id, release id and the `libapp.so` SHA-256 (computed natively from the installed APK) are
    signed;
  - runtime versions and the dynamic-interface hash are signed.
- **Verification:** **Verified** on the phone (wrong baseline, wrong engine) and in unit tests
  (wrong app, wrong release).
- **Residual:** low.

### T10. Corrupted local patch metadata

- **Scenario:** `state.json` or the stored patch is damaged, or edited by someone with access to
  private storage.
- **Mitigation:**
  - corrupted state resets the counters;
  - the stored patch is re-verified cryptographically every start, so state can never cause an
    unverified load.
- **Verification:** **Verified** for a torn stored patch.
- **Residual:** low. With root access, the attacker can modify the app itself anyway. The
  blacklist and highest sequence are not signed, so an attacker with root can reset them.

### T11. App crash during patch activation

- **Scenario:** the new patch crashes during initialisation, before the first frame, after the
  first frame, or throws in `build()`.
- **Mitigation:**
  - the isolated load (initialisation crashes never reach the app);
  - an attempt marker and a failure counter, with blacklisting after 2 failed starts;
  - restoration of the previous confirmed patch;
  - live fallback to AOT for in-process errors;
  - `ApplicationExitInfo`, so user force-stops are not counted.
- **Verification:** **Verified** on the phone for every case (see the test matrix).
- **Residual:** low for initialisation crashes. For state-dependent crashes, up to **2** crashed
  starts before rollback.

### T12. Valid signature on malformed bytecode

- **Scenario:** a correctly signed module with malformed bytecode, from a compiler bug, a
  malicious signer or a stolen key.
- **Root cause (pinned VM source):**
  - the bytecode reader treats malformed input as fatal (`FATAL`, `UNREACHABLE`);
  - its 127 consistency `ASSERT`s are compiled out in release builds;
  - `loadDynamicModule` reads the whole module and immediately runs its entry point;
  - there is no validate-only API;
  - instruction sequences are not verified at load time.
- **Mitigation:**
  - the **isolated load** in a separate Android process (`:otaverify`), before activation, with a
    smoke test of the slots;
  - the crash guard as the backstop.
- **Verification:**
  - **Verified:** of 53 signed malformed modules, 47 were refused safely (CRASHED or REJECTED in
    the verifier process), and the app survived all 65 corpus files.
  - **6 were accepted:** 4 harmless (extra or missing trailing bytes, an unused string), and
    **2 with changed instruction bytes** in functions the smoke test does not run.
- **Residual:** **medium, open blocker.** A signed module with invalid instructions can still crash
  the app when that code runs, up to 2 starts before the crash guard rolls back. See the report,
  section 5.

### T13. FFI or dynamic calls in a module

- **Scenario:**
  - FFI compiles, passes the upstream validator, and aborts the VM (Phase 2);
  - allowed dynamic calls return wrong values (Phase 2).
- **Mitigation:**
  - `patch_guard` refuses them before bytecode generation;
  - dynamic calls are also refused by the upstream validator by default;
  - for FFI, the isolated load is a second line of defence (a signed FFI module crashed only the
    verifier).
- **Verification:** **Verified** (fixtures, the real pipeline, and the phone).
- **Residual:** low, provided the guard is part of the official build.
