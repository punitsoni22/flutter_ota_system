# ADR-0011: Scope is real Dart code push, Android engine fork first

- **Status:** Proposed
- **Date:** 2026-10-30

> **Status update (2026-11-11):** decision 1 was **superseded in practice**. Android code patches
> were built on **stock Flutter without an engine fork**: `OtaBoot.java` (in `ota_client`) selects
> the patched `libapp.so` at process start ([architecture.md](../architecture.md#original-alpha-architecture)). The format name
> `aot-bidiff-android-v1` and the store policy gate (decision 5) are implemented. From the scope
> list in decision 3, **Azure + CI/CD deployment and 1M-install hardening are still planned and
> not implemented** ([roadmap](../roadmap/README.md)). A follow-up ADR should record the
> stock-Flutter approach formally.

## Context

The goal is Shorebird-style OTA: change **any Dart code** of an installed Flutter app on Android and iOS, without a store release, for about 1M active installs. The goal is not a general DevOps platform.

Facts that shape this decision (checked 2026-10-30):

- Shorebird's Flutter engine fork, framework fork, CLI and Rust updater are public (Apache-2.0/MIT, or BSD for the Flutter-derived code). Its **Dart SDK fork is private**. That fork holds the iOS interpreter and linker.
- On Android, Shorebird's engine loads a newly compiled Dart AOT snapshot. On iOS, Apple forbids running downloaded machine code, so new code must run in an interpreter. That is why the private Dart work is needed.
- Shorebird has no self-hosted offering. Its open-source updater and CLI can point at another server (`base_url` in `shorebird.yaml`, `SHOREBIRD_HOSTED_URL`), but they still depend on Shorebird's binary toolchain, which includes the private parts.
- Google Play policy: an app "may not download executable code (such as dex, JAR, .so files) from a source other than Google Play". The exception is code that runs in a virtual machine or interpreter. A patched `libapp.so` sits close to this line.
- Apps will be distributed both through the public stores and internally (enterprise/MDM).

## Decision

1. **Runtime path:** build our own Flutter engine fork, **Android first**. On startup the engine chooses between the store-installed `libapp.so` and a verified patched one. Format name: `aot-bidiff-android-v1`.
2. **iOS:** research track only, until the Android runtime is in production. Options to evaluate then: our own interpreter work, the interpreted subset (`flutter_eval`), or Shorebird's toolchain if its licence allows it.
3. **Scope kept:** release/version matching, artifact storage + CDN, device API, signing, client staging + boot fallback, channels, % rollout, rollback, revoke, Azure + CI/CD, 1M-install hardening.
4. **Scope cut:** the Flutter Web admin console (the CLI and CI drive everything), and telemetry dashboards, alerts and automatic rollout pausing. Only the minimal boot success/failure events stay.
5. **Store policy gate:** every application has a `distribution` field (`public_store` | `enterprise`). The server refuses to publish `aot-bidiff-android-v1` patches to a `public_store` application until a written legal/policy review approves it. Enterprise apps are allowed from the start.

## Consequences

- Good: real code fixes on Android, fully self-owned, no vendor lock-in.
- Good: the backend phases (1–7, 10, 11) need no redesign. `arch`, `runtime_abi`, engine revision and the base/payload/result hashes are already in the model and signature.
- Bad: we must rebuild and re-test the engine fork for **every Flutter version** we support. This is permanent maintenance work.
- Bad: iOS has no delivery date. Public Play Store use is blocked on the policy review.
- Bad: without dashboards, rollout decisions rely on raw boot-failure counts and manual checks.

## Alternatives considered

- Self-hosted server + Shorebird's tools: fastest path to iOS. Rejected for now because it depends on private binaries and unclear licence terms. Keep it as the iOS fallback option.
- Interpreted subset only (`flutter_eval`): no engine fork, but only pre-marked "patchable" code can change. That does not meet the goal.
- Build the whole platform first, runtime last (the original plan): delays the core value. Rejected.
