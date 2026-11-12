# Phase 3 security test matrix

Every Phase 3 security test, its result and evidence. Results are as recorded; nothing marked
PASS was skipped. Evidence paths are relative to
[prototypes/security_hardening/results/](../../prototypes/security_hardening/results/).

Environment:

- **Linux:** x86_64, Dart 3.13.7 (lab SDK).
- **Device:** one Android 13 (API 33) arm64 phone, release build of the Phase 3 host.

Statuses: PASS · FAIL · NOT_TESTED. Two device FAILs are mistakes in the test's *expected reason*;
they are explained below and are not product failures.

## Part 11 matrix

A rejection counts as PASS only if all three hold: the expected reason was logged, the app process
stayed alive, and the previous patch (or the baseline) stayed active.

| Test | Expected | Result | Evidence |
|---|---|---|---|
| Valid signed module | Accept | **PASS**: isolated load OK, installed, loaded, confirmed | `device/p3_01_signed_patch` |
| Modified signed module | Reject | **PASS** (`bad_hash`, v2 kept) | `device/p3_neg_neg_tampered_module`, corpus A07/A08, unit tests |
| Wrong signing key | Reject | **PASS** (`bad_signature` for a trusted id with another key; `unknown_key`) | `device/p3_neg_neg_wrong_key`, `…untrusted_key`, corpus A01/A10 |
| Wrong app id | Reject | **PASS** (`wrong_app`) | corpus A02, unit tests |
| Wrong baseline | Reject | **PASS** (`wrong_baseline`: `libapp.so` SHA-256 hashed on the device) | `device/p3_neg_neg_wrong_baseline`, corpus A03 |
| Wrong engine version | Reject | **PASS** (`wrong_runtime`) | `device/p3_neg_neg_wrong_engine`, corpus A04 |
| Truncated bytecode | Reject safely | **PASS** for 4 of 5; **1 accepted** (last byte removed: unused, harmless) | corpus B01–B05 |
| Malformed bytecode | Reject safely | **47 of 53 refused**; app alive for all; **6 accepted** (4 harmless, **2 changed instructions**) | `corpus/` |
| Validly signed malformed bytecode | Reject safely | Install path **PASS** (verifier crashed, patch blacklisted, v2 kept); see the row above for the limits | `device/p3_neg_malformed_signed`, corpus |
| Direct FFI | Reject before generation | **PASS** (guard, exit 4, no bytecode produced) | `guard/`, `build_artifacts.tsv` (`ffi_guarded`) |
| Transitive FFI | Reject before generation | **PASS** (`patch_ffi -> feature_catalog -> product_service -> dart:ffi`) | `guard/ffi_transitive.guard.log`, `build_artifacts.tsv` |
| Conditional FFI | Reject before generation | **PASS** (all configurations checked) | `guard/ffi_conditional.guard.log` |
| Dynamic invocation | Reject before generation | **PASS** (guard and upstream validator) | `guard/`, `build_artifacts.tsv` (`dynamic_guarded`) |
| Unsupported shared model change | Reject | **PASS** (`host_owned_package` on the device; `pkg_rename` refuses at build, Phase 2) | unit tests |
| Incompatible dependency | Reject | **PASS** (`missing_host_package`, `wrong_interface`; stale closure refused by `pkg_rename`) | unit tests |
| Partial download | Reject | **PASS in behaviour** (`wrong_size`; recorded as FAIL because the test expected the code `truncated`) | `device/p3_neg_neg_partial_download`, corpus A09 |
| Interrupted activation | Recover | **PASS** (killed between staging and activation; leftover removed, previous patch active) | `device/p3_kill_during_activation` |
| Repeated startup crash | Roll back | **PASS** (before/after first frame, `build()` exception: 2 starts, blacklisted, previous patch restored) | `device/p3_crash_*` |
| Blacklisted patch | Refuse activation | **PASS** (refused without another isolated run) | `device/p3_neg_blacklisted_again` |
| Replayed old patch | Reject | **PASS** (`replay`; revocation-list replay refused too) | `device/p3_neg_v1`, `device/p3_revocation_replay` |

## Device: activation and crash recovery (Part 8 / Part 12)

| ID | Scenario | Result |
|---|---|---|
| p3_01 | Normal signed patch | PASS |
| p3_02 | Cold restarts (re-verified every start, no re-install) | PASS |
| p3_03 | Newer patch replaces the older one | PASS |
| p3_neg_ffi_unguarded_signed | Signed FFI module (guard bypassed): verifier crashed, app alive, v2 kept | PASS |
| p3_neg_crash_throw_init | Module throws in initialisation: rejected by the isolated load, never activated | PASS |
| p3_neg_crash_abort_in_entry | Module aborts the process in initialisation: only the verifier died | PASS |
| p3_revocation | Signed revocation of the active patch: previous confirmed patch restored | PASS |
| p3_kill_then_new_patch | A newer patch installs normally after an interrupted activation | PASS |
| p3_stored_torn | Stored patch truncated on disk: detected, previous patch restored | PASS |
| p3_rollback | Rollback, then 3 cold starts: baseline every time | PASS |
| p3_crash_abort_when_logged_in | Crash before the first frame (state-dependent, passes verification) | PASS (rolled back after 2 starts) |
| p3_crash_abort_after_frame | Crash after the first frame | PASS |
| p3_crash_throw_when_logged_in | Exception in `build()`: live fallback, then blacklist | PASS |
| p3_killed_before_confirm | User force-stop before confirmation: not counted | PASS |
| p3_device_restart | Device restart during activation | **NOT_TESTED** (would reboot the owner's phone) |
| p3_new_store_release | New store release over an active patch | **NOT_TESTED in Phase 3** (deferred to the final test phase at the owner's request; passed in Phase 2 with the v1 runtime; the release binding is covered by unit tests) |
| apk_unchanged | Installed APK byte-identical to the baseline after all tests | PASS |

Device suite totals: 26 PASS, 1 FAIL (expected-reason mismatch above), 1 NOT_TESTED.
Corpus: 60 PASS, 7 FAIL:

- the 6 accepted malformed modules (real findings);
- A09 (expected-reason mismatch: rejected with `wrong_size`).

## Linux: unit, fuzz and mutation tests

| Suite | Result | Evidence |
|---|---|---|
| `patch_security` unit tests (all Part 3.3 negatives, canonical form, cross-domain signatures, revocation lists) | 40/40 PASS | `unit_tests.txt` |
| Container fuzz: 20 000 seeded byte-level mutations | PASS: every one rejected with a typed reason; none accepted | `unit_tests.txt` |
| Manifest fuzz: 3 000 re-signed mutations | PASS: 10 accepted, each verified to be a genuinely valid manifest (valid package list or host-package declaration) | `unit_tests.txt` |
| Canonical JSON parser: 20 000 random strings | PASS: no crash, only `FormatException` | `unit_tests.txt` |
| Revocation-list fuzz: 3 000 mutations | PASS: 3 000 rejected | `unit_tests.txt` |
| `patch_guard` fixtures (18 cases, with the upstream validator as ground truth) | 18/18 PASS | `guard/guard_results.tsv` |
| Mutation testing: each check disabled in a temporary copy | 20/20 mutants killed | `mutation/mutations.tsv` |

Ground-truth finding: the upstream `dart2bytecode` validator **accepted all 6 FFI cases** and the
`noSuchMethod` case; it rejected dynamic calls and `dart:mirrors`.

## Limitations of this matrix

- **One device, one Flutter version.** No claim for other devices, ABIs or versions.
- **Prototype only.** Production code (SDK, backend, CLI, signing service) was not changed or
  tested here.
- **Device restart not tested.**
- **New store release:** not re-run in Phase 3 (deferred).
- **Not tested:** fuzzing of `patch_guard` with random package graphs.
- **Verifier coverage:** the isolated load and smoke test cannot detect invalid instructions on
  code paths they do not run.
