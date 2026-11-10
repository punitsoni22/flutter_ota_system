# Limitations and project status

Punit v0.1.0-alpha is an **experimental, self-hosted** open-source project. It has been tested
internally by its maintainers, but it has **not** been comprehensively validated in production,
has **not** had an independent security audit, and has **no** published load tests.

## Status of features

| Mark | Meaning |
|---|---|
| ✅ Tested | Implemented and covered by automated tests (backend: 21, `ota_client`: 19) and/or `scripts/verify_demo.sh` (32 checks), which also run in CI |
| 🟢 Implemented | In the code, used internally, without dedicated automated tests |
| 🟡 Experimental | Works in internal testing on a small number of devices; expect problems |
| 🔭 Planned | Not implemented ([roadmap](roadmap/README.md)) |
| ❌ Unsupported | Not possible or out of scope today |

### Server

| Feature | Status |
|---|---|
| Apps, channels, releases, patches (create, list, delete test releases) | ✅ |
| Release ↔ patch version isolation; newest-patch selection; arch matching | ✅ |
| ES256 signing; signature verifies with the published public key | ✅ |
| Channels; percentage rollout that is deterministic and sticky | ✅ |
| Rollback, revoke, bad-patch lists in every response; anti-downgrade | ✅ |
| Skipping patches that crashed on a device | ✅ |
| Store-policy gate for `public_store` code patches | ✅ |
| Event counters per patch; device summary | ✅ |
| Private store-build storage; S3 storage keeps patches public and releases private | ✅ |
| Production startup safety checks | ✅ |
| Alembic migrations on startup | ✅ (run in every local stack and CI start) |
| Admin page `/admin` | 🟢 (one smoke test) |
| Local Docker stack | ✅ on Linux; macOS/Windows not tested |
| Single-server production deploy (`deploy/`, Caddy) | 🟡 Draft, not verified end to end |
| S3-compatible storage against real providers | 🟢 Used internally; tests use a mock |
| Backup script / restore | 🟢 / restore not tested |

### Client and tooling

| Feature | Status |
|---|---|
| `mock-v1` flow: check → verify → download → stage → activate → confirm | ✅ |
| Crash protection (unconfirmed start falls back) | ✅ |
| Tampered file / forged signature rejection | ✅ |
| Server rollback, store-version change, corrupted file on disk | ✅ |
| Runtime channel switching | ✅ |
| `OTADIF01` diff: Python → Dart round trip | ✅ |
| Android code patches (`aot-bidiff-android-v1`) end to end | 🟡 Experimental. Native boot logic is unit-tested in Dart with a fake native side; the real Android path was tested manually on a few devices |
| `ota release android` / `ota patch android` | 🟡 Experimental |
| iOS (any patch type) | ❌ Not tested. Code patches unsupported |

## Platform limitations

| Platform | Status |
|---|---|
| Android code patches | 🟡 Release builds only. Requires the exact registered APK/AAB and the same Flutter version |
| Android `mock-v1` | ✅ |
| iOS code patches | ❌ Apple forbids running downloaded native code. An interpreter-based approach is research only ([roadmap](roadmap/runtime-ios-research.md)) |
| iOS `mock-v1` | ❌ Not tested. The plugin declares only Android |
| Web, desktop | ❌ Not supported |

## Flutter version compatibility

- Requirements of `ota_client`: Dart ≥ 3.12, Flutter ≥ 3.27.
- Analysis and unit tests ran with Flutter 3.44 stable (CI uses the current stable).
- Android code patches depend on Flutter's internal loader option
  (`--aot-shared-library-name`). They were tested only with the Flutter versions the maintainers
  used. **No Flutter compatibility matrix is published.** A future Flutter release could break
  them.
- A patch must be built with exactly the Flutter version of its release. Every Flutter upgrade
  needs a new store release.

## Native code and patch-engine limitations

- A code patch can change **only Dart code** (including pure-Dart packages). Plugins with native
  code, native libraries, Java/Kotlin, the manifest, resources and assets need a store release.
- A patch is a binary diff against one store build. A rebuilt APK/AAB is a different build.
- Patch size depends on how much compiled code changes. No size benchmarks are published.
- Activation needs an app restart; running code is never swapped live.
- Crashes after a patch was confirmed, or in native code before the boot hook, are not detected
  automatically.
- Debug builds ignore code patches.
- Google Play's policy on this approach has not been ruled on publicly. The store-policy decision
  is yours ([flutter-integration.md](flutter-integration.md#store-policy)).

## Operational limitations

- No push: devices learn about patches, rollbacks and revocations only when the app calls
  `checkForUpdate()`. The client has no timer.
- No automatic rollout pausing, alerts, dashboards, scheduling or targeting beyond
  channel/release/arch/percentage.
- Telemetry is counts per patch only; no per-device history.
- No structured logs, metrics endpoint or tracing.
- Re-creating a deleted release with the same version breaks existing installs (`release id
  changed`, [KI-1](known-issues.md#ki-1-re-creating-a-deleted-release-breaks-existing-installs)).
- The `promote` safety checks run only in the CLI; the server does not enforce them
  ([KI-4](known-issues.md#ki-4-promote-safety-checks-are-enforced-only-by-the-cli)).
- Channels can be created only through the API; they cannot be renamed or deleted
  ([KI-3](known-issues.md#ki-3-channels-can-be-created-only-through-the-api)).

All known bugs, with priorities: [known-issues.md](known-issues.md).
- API, schema and patch formats may change without migration paths before v1.0.

## Security status

- **No independent security audit.**
- One shared admin API key: no users, roles (RBAC), SSO, MFA or audit log.
- Signing key in a local file or environment variable; no Key Vault, KMS or HSM; no rotation
  tooling.
- No short-lived signed download URLs; patch files are public by hash.
- Open device registration, no rate limiting, no per-token revocation.

Details: [security.md](security.md).

## Performance and scale

**No load tests have been run, and Punit makes no capacity claim.** In particular, reliability at
**1 million active installs has not been established**. That number appears in the roadmap only
as a design goal.

What the design does to keep the hot path cheap (not measured): the update check is a few indexed
queries, device rows are written at most hourly unless something changes, patch files are
immutable and cacheable, and rollout needs no per-device state. What it lacks for large fleets:
any cache (every check reads PostgreSQL), rate limiting, and measured numbers.

## Production testing gaps

Before relying on Punit, someone needs to:

- run the server under realistic load and measure it;
- test the single-server deploy, backups, restores and upgrades;
- test Android code patches across Flutter versions, Android versions, ABIs and devices;
- review the security model independently;
- test failure modes (network loss during download, full disk, server outage during rollout).

## What is planned

See the [roadmap](roadmap/README.md) and the list of
[installation improvements](roadmap/installation-improvements.md).
