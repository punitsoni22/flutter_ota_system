# Verification process isolation (Phase 3C prototype)

Status: experimental prototype, Android only. **Result (2026-11-12, Android 13 phone): isolation
was NOT achieved.** Flutter cannot start in an Android isolated process in a release build (section
4). The app falls back, with a log line, to the Phase 3 same-UID `:otaverify` process. Nothing here
is a sandbox.

## 1. Why a separate process at all

The Dart VM has no validate-only API: loading a module runs its entry point, and in the pinned VM
malformed bytecode aborts the process ([phase-3c-vm-investigation.md](phase-3c-vm-investigation.md)).
Phase 3 therefore loaded every new patch first in a separate process, `:otaverify`, so a crash only
killed that process. Phase 3C adds an in-VM bytecode verifier
([bytecode-verifier.md](bytecode-verifier.md)); the separate process stays as a second layer for VM
defects the verifier does not cover.

The Phase 3 `:otaverify` process runs under the **same Linux UID** as the app. It can read and write
the app's private files, including the patch store. Phase 3C moves verification into an Android
**isolated process**.

## 2. Design

| Element | Implementation |
| --- | --- |
| Isolated service | `IsolatedVerifierService`, declared with `android:isolatedProcess="true"` and `android:process=":otaverify_iso"`, `android:exported="false"` (added to the manifest by `scripts/build_host.sh`). |
| Separate UID | Android starts isolated services under a temporary UID with none of the app's permissions. |
| Input | The main process opens the candidate module with `ParcelFileDescriptor.MODE_READ_ONLY` and sends **only that descriptor**. The isolated process reads the bytes and passes them to Dart; it never receives a path into the app's storage. |
| Output | A status message: `OK`, `REJECTED` (clean Dart error, e.g. "Bytecode verification failed"), `CRASHED` (process died), `TIMEOUT`, or `UNAVAILABLE`. |
| Lifetime | One module per process. After reporting, the process exits; on timeout the app unbinds (an isolated process has another UID, so the app cannot kill it directly; the system destroys it when unbound). |
| Fallback | If Flutter cannot start inside the isolated process, the service reports `UNAVAILABLE` (never `OK`), the app logs `ISOLATION_FALLBACK` and uses the Phase 3 `:otaverify` process. |

Code: `host_overlay/android/IsolatedVerifierService.kt`, `MainActivity.kt` (`verifyIsolated`),
`host_overlay/lib/verifier_main.dart`, `host_overlay/lib/patch_runtime.dart`
(`verifyInIsolatedProcess`).

## 3. Isolation evidence recorded at run time

Before loading, the isolated process records probes, which the app logs (`ISOLATION process=…
probes=…`):

| Probe | Expected in an isolated process |
| --- | --- |
| `uid` vs `app_uid` | different |
| `is_isolated` (`Process.isIsolated()`) | `true` |
| `read_private_store`, `read_private_state` | `DENIED` |
| `write_private_store` (Kotlin and Dart) | `DENIED` |
| `read_external_inbox` (app's external files) | `DENIED` |
| `network_socket` (local socket only; no traffic leaves the device) | `DENIED` |

The device suite turns these into the test `p3_isolation`; on the phone it fails because the
isolated process never reaches the probe report (section 4).

## 4. Device result: Flutter cannot run in an isolated process (release build)

Observed on the test phone (Android 13, arm64) for every candidate, valid or malformed:

1. The isolated process starts (separate UID `u0i…`, SELinux domain `isolated_app`).
2. It cannot create app directories (`mkdir failed: ENOENT`); Flutter continues.
3. The GPU device is denied (`open(/dev/kgsl-3d0) failed: errno 13`) and SurfaceFlinger lookup is
   denied by SELinux (`avc: denied { find } … name=SurfaceFlinger … isolated_app`).
4. The engine's raster thread then crashes with a null-pointer `SIGSEGV` during start-up, **before**
   Dart asks for the module.
5. `--enable-software-rendering` does not help: release builds ignore it ("not allowed in release
   builds").

Handling (implemented and tested): the isolated service sends a "module taken" message the moment
Dart requests the bytes. A death **before** that message is reported as `UNAVAILABLE` (an
environment failure, never `OK`) and the app logs `ISOLATION_FALLBACK` and verifies in the same-UID
`:otaverify` process. A death **after** it is `CRASHED` and attributed to the module.

Consequence: the second layer is still a **separate process**, but with the app's UID, so it can
read the app's files. The primary defence against malformed bytecode is now the in-VM verifier
([bytecode-verifier.md](bytecode-verifier.md)), which refused B25 and B27 with a clean error on the
phone.

What would be needed for real isolation (not done, out of Phase 3C scope): a headless Dart embedder
without the Flutter rendering stack inside the isolated process, or running the reader and verifier
as a plain native library there.

## 5. What isolation does not give

- It does not stop a module from using CPU or memory inside the verifier process (a timeout limits
  wall time only).
- It is not a security boundary against kernel or Binder exploits.
- It verifies the module once, before activation. In the main process the module later runs with
  the app's full permissions; the in-VM verifier and the runtime guards apply there too, but the
  isolated process does not.
