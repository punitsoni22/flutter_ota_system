# ADR-0001: The platform is independent of patch execution technology

- **Status:** Accepted (implemented: `PatchRuntime` in `packages/ota_client/lib/src/runtime.dart`)
- **Date:** 2026-09-30

> **Status update (2026-11-11):** the decision holds. In the code, `PatchRuntime` lives in
> `packages/ota_client/lib/src/runtime.dart` (there is no separate `ota_runtime_api` package).
> The original alpha's Android runtime uses stock Flutter; the bytecode runtime (`FlutterOta`,
> v0.2.0-alpha) uses the Flutter OTA custom engine (see the
> [ADR-0011](0011-scope-and-runtime-path.md) update).

## Context

Flutter release builds are AOT-compiled, so you cannot simply swap in new Dart code. Shorebird solves this with forks of the Flutter engine and Dart SDK, and part of its Dart fork is not public. Building an equivalent runtime is estimated at 40–100+ person-weeks. The rest of the OTA platform (API, storage, signing, rollout, telemetry, Azure) is about 31–49 person-weeks and is useful on its own.

## Decision

The platform (backend, protocol, client SDK) never depends on how a patch is executed. Execution sits behind the Dart interface `PatchRuntime` in `packages/ota_runtime_api`:

```dart
abstract interface class PatchRuntime {
  Future<RuntimeCompatibility> checkCompatibility(PatchManifest manifest);
  Future<void> stagePatch(PatchArtifact artifact);
  Future<void> activateStagedPatch();
  Future<void> markBootSuccessful();
  Future<void> rollback();
  Future<String?> activePatchId();
}
```

Implementations are delivered in this order (updated by [ADR-0011](0011-scope-and-runtime-path.md)): `MockPatchRuntime` (signed inert file, for testing the platform) → `AndroidAotPatchRuntime` (our Android engine fork) → an iOS runtime, chosen after research. The backend treats `artifact_format` as an opaque, validated string.

## Consequences

- Good: the full platform reaches production with `mock-v1` (remote config, feature data) before any runtime research.
- Good: runtime experiments cannot break the control plane.
- Bad: `mock-v1` cannot fix code bugs. Real code patches wait for Phase 12.

## Alternatives considered

- Build the runtime first: blocks all platform work on the riskiest research.
- Fork Shorebird's engine directly: the Dart SDK changes it needs are not public.
