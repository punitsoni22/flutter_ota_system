# Phase 0 — Protocol decisions (≈0.5 pw)

> **Roadmap status: 🟡 partial.**
> - ✅ ADR-0001, ADR-0002 and ADR-0011 are written (status *Proposed*).
> - 🟡 ADR-0003 to ADR-0007 and ADR-0010 are **decided and implemented in the code**, but not yet
>   written up. ADR-0008 and ADR-0009 are planned. See the [ADR index](../adr/README.md).
> - 🔭 `docs/protocol/manifest-v1.md` (step 0.4) does not exist yet. ADR-0002 holds the canonical
>   encoding and its test vector.

**Goal:** write down the decisions that are expensive to change later, *before* writing code that depends on them.

**What is an ADR?** A one-page Markdown file: *context → decision → consequences*. Six months from now, when you wonder "why is the signature 64 bytes?", the ADR answers. ADRs live in `docs/adr/` and are numbered.

---

## 0.1 Read the template

**Do:** open [docs/adr/0000-template.md](../adr/0000-template.md). Every ADR copies this structure.

---

## 0.2 Review and accept the drafted ADRs

Three ADRs are already drafted with status **Proposed**:

| File | Decision |
|---|---|
| [0001-runtime-abstraction.md](../adr/0001-runtime-abstraction.md) | The platform never depends on a specific patch execution technology |
| [0002-signature-scheme.md](../adr/0002-signature-scheme.md) | ECDSA P-256 (ES256) over a length-prefixed canonical encoding |
| [0011-scope-and-runtime-path.md](../adr/0011-scope-and-runtime-path.md) | Scope: real Dart code push, Android first (built on stock Flutter, see the ADR's status update), iOS research later, no web console or dashboards |

**Do:** read both. If you agree, change `Status: Proposed` to `Status: Accepted`. If you disagree (for example you prefer RSA-PSS), edit the decision and the consequences.

**Check:** both files say `Accepted`.

---

## 0.3 Write the remaining ADRs

**Why:** each of these closes a gap or open question in the original design.

**Do:** copy the template to each new file and fill it in. The recommended decision is given, so your job is to understand it and write it in your own words.

| File to create | Recommended decision |
|---|---|
| `0003-patch-formats.md` | Closed list: `mock-v1` (inert test file), `aot-bidiff-android-v1` (binary diff of `libapp.so`, see [Track R](runtime-android-engine.md)), `evc-v1` (reserved for iOS research). The client ignores unknown formats instead of crashing |
| `0004-rollout-bucket.md` | `bucket = first 8 bytes of HMAC-SHA256(server_secret, encode(app_id, installation_id, cohort_seed))` as a big-endian integer, `mod 10000`. Eligible if `bucket < percentage_basis_points`. Details in Phase 7 |
| `0005-rollback-signalling.md` | **Every** `/v1/updates/check` response (even "no update") contains `revoked_patch_ids: []` and `rollback_to_patch_number: int \| null`. Otherwise devices already on a bad patch never learn about it |
| `0006-anti-replay.md` | The client refuses a patch whose number is ≤ its highest installed number, unless the server marks it as the rollback target. The signature covers `release_id` and `patch_number`, so a patch for one release cannot be reused on another |
| `0007-key-rotation.md` | The app embeds a **set** of public keys (`key_id → key`), not one key. Always ship with the current key plus the next key. Rotating means shipping a store release with the new set |
| `0008-cdn-vs-sas.md` | Default: public immutable CDN URL (best caching; integrity comes from the signature). Optional: short-lived SAS URL for customers who need confidentiality |
| `0009-telemetry-pipeline.md` | `POST /v1/events/batch` returns 202 and forwards to Event Hubs. It never writes Postgres directly |
| `0010-store-policy.md` | Each application has `distribution = public_store \| enterprise`. `aot-bidiff-android-v1` is allowed for `enterprise` apps, and for `public_store` apps only when `aot_policy_approved = true` after a legal review. Patches may never add permissions, plugins, assets or native code |

**Check:** `ls docs/adr` shows 0000–0010. Commit: `git commit -am "phase 0: ADRs"`.

---

## 0.4 Write the manifest spec

**Why:** the Dart client and Python server must agree byte-for-byte on what gets signed.

**Do:** create `docs/protocol/manifest-v1.md`. Copy the "Canonical encoding" section and the test vector from ADR-0002 into it, plus a JSON example of the patch manifest (take a real `/v1/updates/check` response from `scripts/verify_demo.sh` or the API docs at `/docs`), using `mock-v1` as the format.

**Check:** someone who has never seen your code could implement the encoder from this file alone.
