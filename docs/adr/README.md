# Architecture Decision Records (ADRs)

An ADR is a short document that records one design decision: the context, the decision and its
consequences. To write one, copy [0000-template.md](0000-template.md).

Some decisions are **implemented in the code but not written up yet**. The code and comments refer
to them by number. Until each file exists, the summary below (taken from the current code) is the
reference.

| ADR | Decision | Document | In the code |
|---|---|---|---|
| 0001 | The platform does not depend on how a patch runs (`PatchRuntime`) | [0001-runtime-abstraction.md](0001-runtime-abstraction.md) | ✅ `packages/ota_client/lib/src/runtime.dart` |
| 0002 | ES256 signature over a length-prefixed canonical encoding | [0002-signature-scheme.md](0002-signature-scheme.md) | ✅ `backend/app/canonical.py`, `packages/ota_client/lib/src/canonical.dart` |
| 0003 | Closed list of patch formats: `mock-v1`, `aot-bidiff-android-v1`, `evc-v1` (reserved), `dbc-v1` (bytecode). The client ignores formats it does not support | not written yet | ✅ `ARTIFACT_FORMATS` in `backend/app/models.py` |
| 0004 | Rollout bucket = first 8 bytes of HMAC-SHA256(server secret, length-prefixed app id + installation id + cohort seed), big-endian, mod 10000. A device is in the rollout if its bucket is below the rollout in basis points | not written yet | ✅ `backend/app/bucket.py` |
| 0005 | Every update-check response, even "no update", carries the bad-patch lists and the rollback target | not written yet | ✅ `backend/app/schemas.py`, `ota_client.dart` |
| 0006 | Anti-replay: the client never accepts a lower patch number unless the server marks it as the rollback target. The signature covers the release and patch number | not written yet | ✅ `packages/ota_client/lib/src/state.dart` |
| 0007 | Apps embed a **set** of trusted public keys (`key_id → key`), so keys can be rotated with a store release | not written yet | 🟡 Key set supported in `signature.dart`; no rotation runbook |
| 0008 | Public immutable CDN URLs by default; short-lived signed URLs as an option | not written yet | 🟡 Public URLs only; 🔭 signed URLs planned |
| 0009 | Telemetry ingestion pipeline (Event Hubs) | not written yet | 🔭 Planned. Today events are counted directly in PostgreSQL |
| 0010 | Store policy: each app is `public_store` or `enterprise`; Android code patches for `public_store` apps need a recorded policy approval | not written yet | ✅ `distribution`, `aot_policy_approved` in `backend/app/models.py` |
| 0011 | Scope: real Dart code push, Android first, iOS research later | [0011-scope-and-runtime-path.md](0011-scope-and-runtime-path.md) | 🟡 Original alpha: no engine fork. Bytecode architecture: custom engine (Dart interpreter + verifier) shipped as the toolchain overlay (see its status update) |
| 0012 | How to ship a custom engine to CI | not written yet; the custom engine ships as a signed toolchain overlay ([toolchain management](../toolchain-management.md)) | — |

ADR statuses are in each file. See the [roadmap](../roadmap/README.md) for what is
implemented, partial or planned.

**Bytecode architecture.** The decisions behind the experimental bytecode architecture (custom
engine, developer-owned signing, feature packages, local builds) are summarised in
[architecture.md](../architecture.md) and [security.md](../security.md). A formal ADR for them is
still to be written.
