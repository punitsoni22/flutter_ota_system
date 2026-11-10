# Phase 7 — Rollout, rollback, revoke (3–4 pw) → Milestone D

> **Roadmap status: ✅ mostly implemented.** Deterministic HMAC buckets (`backend/app/bucket.py`),
> publish / rollout / rollback / revoke endpoints, bad-patch lists on every check, and a fleet
> simulator (`scripts/simulate_fleet.py`).
> 🔭 Not built: targeting (7.5, optional) and the deployment-head cache (7.8). **There is no Redis
> and no in-process cache**: every check reads PostgreSQL.

**Goal:** release a patch to 1% of users, watch it, expand to 10% → 25% → 50% → 100%, and stop or undo it instantly if something is wrong.

**New concepts:** deterministic bucketing with HMAC, monotonic expansion, cache invalidation, append-only event ledgers.

Branch: `git switch -c phase-7-rollout`.

---

## 7.1 Understand deterministic buckets

**Why not `random()`?** If each check rolls a die, a device could get the patch on one check and not the next. Rollouts become unpredictable, and "10%" drifts toward 100% over time.

**Instead:** every device gets a fixed number 0–9999, computed from its identity:

```
bucket = first 8 bytes of HMAC-SHA256(server_secret,
             encode(application_id, installation_id, cohort_seed))
         as a big-endian integer, mod 10000

eligible = bucket < percentage_basis_points      (10% = 1000, 1% = 100)
```

- **Stable:** same device → same bucket, every time.
- **Monotonic:** a device in the 1% group (bucket < 100) is automatically in 10% (bucket < 1000). Expanding never removes anyone.
- **Secret:** because of the HMAC secret, users can't compute their bucket and force themselves into a rollout.
- **cohort_seed:** stored on the rollout. Keep it constant within a rollout so expansion is monotonic. A new seed per patch means the canary group is a different 1% each time, so the same users aren't always the guinea pigs.

Use the same length-prefixed `encode` from ADR-0002 (without the `OTA-PATCH-V1` prefix), so field boundaries are unambiguous.

**Test vector** to put in your unit test: secret `b"test-cohort-secret"`, app `6f629161-5d63-4caa-9174-0ad1b225ad37`, installation `e244732c-6ee1-4754-bf5c-a62044c300f6`, seed `seed-1` → bucket **5299**.

---

## 7.2 Implement and test the bucket function

**Do:**
1. Add the setting `cohort_secret` (Key Vault in Phase 10).
2. Create `app/rollout/bucket.py` with `compute_bucket(secret, app_id, installation_id, seed) -> int` and `is_eligible(bucket, basis_points) -> bool`.
3. Tests:
   - the test vector above;
   - same input → same output;
   - **uniformity:** compute 100,000 buckets for random installation IDs. Each tenth (0–999, 1000–1999, …) should hold roughly 10% (allow ±1%);
   - **monotonic:** every device eligible at 100 bp is also eligible at 1000 bp.

---

## 7.3 Rollout API

**Do:** endpoints (temporary admin key until Phase 8):

| Method | Path | Does |
|---|---|---|
| POST | `/v1/admin/rollouts` | Create for (patch, channel) with `percentage_basis_points`, new random `cohort_seed`, state `running` |
| PATCH | `/v1/admin/rollouts/{id}` | Change percentage (**only upward** unless `force=true`), or change state: `paused`, `running`, `completed`, `aborted` |
| GET | `/v1/admin/rollouts?channel_id=` | List |

Rules:
- A patch must be `published` to have a running rollout.
- Only one active (`running`/`paused`) rollout per (patch, channel). The partial unique index enforces it. Turn the database error into a clean 409.
- Every change writes a `deployment_events` row (with before/after JSON) **and** an `audit_events` row, in the same transaction.

---

## 7.4 Use the rollout in `/updates/check`

**Do:** in the check service (Phase 3.6, step 6):

```
if rollout.state == "paused"  → NOT_ELIGIBLE for devices not already on this patch
bucket = compute_bucket(...)
if not is_eligible(bucket, rollout.percentage_basis_points) → NOT_ELIGIBLE
```

Include `"rollout": {"id": ..., "bucket": ..., "threshold": ...}` in the response. Telemetry uses it in Phase 9 to compare patched vs control groups.

**Check:** integration test: 1000 fake devices, 10% rollout → roughly 100 get the patch. Raise to 25% → all of the first ~100 still get it, plus ~150 more.

---

## 7.5 Targeting (optional, small)

**Do:** support two keys in `rollouts.targeting` JSON:
- `{"installation_ids": [...]}`: those devices are always eligible (internal testers).
- `{"min_build_number": 120}`: excludes older builds.

Keep it small. Validate the JSON with a Pydantic model so typos are rejected.

---

## 7.6 Rollback

**Meaning:** "patch 5 is bad, the channel goes back to patch 4."

**Do:** `POST /v1/admin/patches/{id}/rollback`:
1. Abort patch 5's rollout on that channel.
2. The channel head becomes the previous published patch (4), or none.
3. Check responses now include `"rollback_to_patch_number": 4` (or `0` for the store version) for devices reporting patch 5.
4. Write `deployment_events` type `rollback`.

**Client side:** when it sees `rollback_to_patch_number` below its active number, it switches active back to that patch (if it's still on disk and verified) or to the store version, **at the next restart**, using the boot protocol.

---

## 7.7 Revoke

**Meaning:** "patch 5 must never run again, anywhere." It is stronger than rollback.

**Do:** `POST /v1/admin/patches/{id}/revoke`:
1. State machine → `revoked` (terminal).
2. Abort all its rollouts.
3. Its ID appears in `revoked_patch_ids` of **every** check response for that release.
4. `deployment_events` type `revoke`.

**Client:** adds it to the persisted `revokedPatchIds`. At the next start, if it's active, it falls back (Phase 5.7).

---

## 7.8 Deployment head cache

**Why:** at 10,000 checks/second, loading "the current patch for this channel" from Postgres every time is wasteful. It changes maybe once a day.

**Do:**
1. Add an in-process cache (a dict with an expiry time, or `cachetools.TTLCache`), keyed `ota:head:{app}:{release}:{channel}:{platform}:{arch}`, TTL 10 seconds.
2. Include a `deployment_generation` number in the cached value. It increases on every rollout, rollback or revoke.
3. With a 10-second TTL, admin changes take effect within 10 seconds everywhere. That's acceptable. Instant invalidation through Redis pub/sub is a Phase 11 decision, and only if load tests show you need Redis.

**Check:** a test that changes the rollout and asserts the check reflects it after the TTL (use an injectable clock rather than `sleep`).

---

## 7.9 Simulated fleet test

**Do:** a script `scripts/simulate_fleet.py` that registers 2,000 fake devices, runs checks, and prints how many got the patch. Run it at 1%, 10% and 100%, pause, roll back, and revoke.

**Check:** 🎉 **Milestone D** when the numbers match expectations at each step.

---

## Phase 7 is done when

- [ ] Bucket tests pass (vector, stable, uniform, monotonic)
- [ ] Percentage can only go up unless forced. Pause stops new installs
- [ ] Rollback and revoke both reach devices through the check response
- [ ] Every change is in `deployment_events` and `audit_events`
