# Phase 3 — Device control plane (2–3 pw) → Milestone A

**Goal:** a device can register, get a token, send heartbeats, and ask "is there an update for me?".

**New concepts:** JWT access tokens, refresh tokens, hashing secrets, a read-only hot path.

Branch: `git switch -c phase-3-device-api`.

---

## 3.1 Add dependencies and settings

**Do:** add `"pyjwt>=2.9"` to `dependencies` in `backend/pyproject.toml`, then `make backend-install`. Add to `Settings`:

```python
device_jwt_secret: str = "change-me-local-only"   # Key Vault in Phase 10
device_access_token_ttl_seconds: int = 3600
device_refresh_token_ttl_days: int = 90
check_interval_seconds: int = 1800
check_jitter_seconds: int = 600
```

Make the app refuse to start if `env` is not `local`/`test` and the secret is still the default. Add this check in `create_app`.

---

## 3.2 Token helpers

**Why:**
- The **access token** is a short-lived JWT (1 hour). The server can verify it without a database lookup, which matters at 1M devices.
- The **refresh token** is a long random secret used to get new access tokens. It is stored **only as a hash**, so a database leak does not leak usable tokens.

**Do:** `app/auth/device_tokens.py`:

```python
import hashlib
import secrets
import uuid
from datetime import UTC, datetime, timedelta

import jwt

AUDIENCE = "ota-device"
ISSUER = "flutter-ota"


def issue_access_token(secret: str, device_id: uuid.UUID, application_id: uuid.UUID,
                       ttl_seconds: int) -> str:
    now = datetime.now(UTC)
    claims = {
        "sub": str(device_id),
        "app": str(application_id),
        "aud": AUDIENCE,
        "iss": ISSUER,
        "iat": now,
        "exp": now + timedelta(seconds=ttl_seconds),
    }
    return jwt.encode(claims, secret, algorithm="HS256")


def decode_access_token(secret: str, token: str) -> dict:
    # Raises jwt.PyJWTError on a bad signature, expiry, or wrong audience.
    return jwt.decode(token, secret, algorithms=["HS256"], audience=AUDIENCE, issuer=ISSUER)


def new_refresh_token() -> tuple[str, bytes]:
    """Returns (token for the device, hash for the database)."""
    token = secrets.token_urlsafe(32)
    return token, hash_refresh_token(token)


def hash_refresh_token(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()
```

Then a FastAPI dependency `current_device` using `fastapi.security.HTTPBearer` that decodes the token and returns `(device_id, application_id)`, or raises 401.

**Check:** unit tests covering a valid token, an expired token (issue with `ttl_seconds=-1`), a wrong audience, and a tampered token.

---

## 3.3 `POST /v1/devices/register`

**Why:** the first call every install makes. It must be **idempotent**: calling it twice with the same `installation_id` returns the same device, not a new one.

**Do:**
- Request/response schemas exactly as in blueprint page 17–18. The client generates `installation_id` (a UUID) on first launch and stores it.
- Look up the application, release and channel. Return 404 or 422 with a clear message if any is unknown.
- Upsert the device with `INSERT ... ON CONFLICT (application_id, installation_id) DO UPDATE` (SQLAlchemy: `from sqlalchemy.dialects.postgresql import insert`).
- Create a `device_credentials` row with the refresh token hash and `expires_at`.
- Create or update `device_patch_state`.
- Return `device_id`, `access_token`, `expires_in`, `refresh_token`, `check_after_seconds`.

> Anyone with your app can call register. That is normal. Protect it with rate limits (Front Door WAF in Phase 10). Stronger device attestation (Play Integrity / App Attest) is optional later.

**Check:** calling register twice with the same `installation_id` gives the same `device_id` and 2 credential rows.

---

## 3.4 `POST /v1/devices/token/refresh`

**Do:**
1. Hash the incoming refresh token and find an **unrevoked, unexpired** credential for that device.
2. Revoke it (`revoked_at = now()`), create a new one, and return a new access and refresh token. This is **rotation**.
3. **Reuse detection:** if the token matches a credential that is *already revoked*, someone stole it. Revoke **all** credentials of that device and return 401. The real app re-registers.

**Check:** tests for normal refresh, an unknown token (401), and a replayed old token (401 plus all credentials revoked).

---

## 3.5 `POST /v1/devices/heartbeat`

**Why:** updates `last_seen` and the device's current patch. It is kept separate from the check so the check never writes to the database.

**Do:** auth with `current_device`. Update `devices.last_seen`, `devices.current_patch_id`, and `device_patch_state`. Return 204.

---

## 3.6 `GET /v1/updates/check` — the hot path

**Why:** this endpoint takes up to 10,000 requests/second at peak. It must be **read-only** and do as little work as possible.

**Do:** `app/services/update_check.py`, following the blueprint's order:

```
1. device = current_device (from JWT, no DB)
2. head = load deployment head for (app, release, channel, platform, arch)
      → the newest *published* patch with a running/paused/completed rollout
        on this channel, plus its artifact for this arch
3. revoked = IDs of revoked patches for this release
4. if no head                         → CHANNEL_HAS_NO_PATCH
5. compat = check_compatibility(...)  → INCOMPATIBLE_*
6. bucket check (Phase 7; until then everyone is eligible) → NOT_ELIGIBLE
7. if head.patch_number <= current    → UP_TO_DATE
8. else                               → update_available: true + artifact manifest
```

Every response, including "no update", contains:

```json
{
  "next_check_after_seconds": 1800,
  "jitter_seconds": 600,
  "revoked_patch_ids": ["..."],
  "rollback_to_patch_number": null
}
```

The artifact `url` is a placeholder until Phase 4. Use `f"{settings.cdn_base_url}/{blob_key}"`.

Log a single line per check with the decision and reason. It will become a metric in Phase 9.

**Check:** integration tests for every reason code, using data created through the services from Phase 2.

---

## 3.7 Rate limiting (basic)

**Do:** for now, a simple in-memory per-IP limit on `register` and `refresh` (for example `slowapi`, or a small dict with timestamps). The real protection is Front Door WAF in Phase 10.

---

## 3.8 Publish the OpenAPI contract

**Why:** the Dart client in Phase 5 is written against this contract.

**Do:** add a script `backend/scripts/export_openapi.py` that writes `create_app().openapi()` to `docs/api/openapi.json`. Add a CI step that fails if the committed file is out of date:

```bash
python scripts/export_openapi.py && git diff --exit-code ../docs/api/openapi.json
```

---

## 3.9 Milestone A demo script

**Do:** write `scripts/demo_milestone_a.sh` using `curl` and `jq` (`sudo apt install jq`):

1. Admin: create app, channel `production`, release, and patch (don't publish yet).
2. Device: register → store the token.
3. Check → `CHANNEL_HAS_NO_PATCH`.
4. Admin: validate + publish the patch (and create a 100% rollout once Phase 7 exists).
5. Check → `update_available: true`.

**Check:** the script runs start to finish against `make up`. 🎉 **Milestone A reached.**

---

## Phase 3 is done when

- [ ] Register is idempotent. Refresh rotates and detects reuse
- [ ] Check never writes to the database (verify: no `UPDATE`/`INSERT` in its SQL log)
- [ ] Every reason code has a test
- [ ] `docs/api/openapi.json` is committed and checked in CI
- [ ] Demo script works
