# Phase 8 — Admin console and RBAC (2–4 pw)

> **Roadmap status: 🔭 planned.** Today there is **one shared admin API key** (`OTA_ADMIN_API_KEY`)
> and one static admin page at `/admin`. **Not built:** Entra ID / SSO, users, **roles (RBAC)**,
> idempotency keys, an **audit log** and the Flutter Web console (8.6, cut from scope).

**Goal:** people log in with Microsoft accounts. What they can do depends on their role. Every action is recorded.

**New concepts:** Microsoft Entra ID (formerly Azure AD), app roles, OAuth tokens, RBAC (role-based access control), idempotency keys.

> **Scope note (ADR-0011):** the Flutter Web console is out of scope. **Skip 8.6.** Do everything else: the roles, Entra ID tokens and idempotency protect the admin API that the `ota` CLI and GitHub Actions call.

Branch: `git switch -c phase-8-admin`.

---

## 8.1 Roles and permissions

Planned roles:

| Role | Read | Create draft | Publish | Rollback / revoke | Signing admin |
|---|---|---|---|---|---|
| Viewer | ✓ | | | | |
| Developer | ✓ | ✓ | | | |
| ReleaseManager | ✓ | ✓ | non-prod channels only | | |
| Publisher | ✓ | ✓ | ✓ | ✓ | |
| SecurityAdmin | ✓ | | | emergency revoke | ✓ |

**Do:** write this table as code (`app/auth/permissions.py`): an enum of actions plus a dict `role → set of actions`. The table becomes the single source of truth.

---

## 8.2 Register the API in Entra ID

**Do** (Azure portal → *Microsoft Entra ID* → *App registrations*):
1. **New registration** → name `ota-admin-api` → single tenant.
2. **Expose an API** → Application ID URI `api://ota-admin`, and add a scope `access`.
3. **App roles** → create `Viewer`, `Developer`, `ReleaseManager`, `Publisher`, `SecurityAdmin` (allowed member types: Users/Groups).
4. **Enterprise applications** → `ota-admin-api` → *Users and groups* → assign yourself `Publisher`.

Write down the **Tenant ID** and **Application (client) ID**.

Then register the admin web app: **New registration** → `ota-admin-web` → platform **Single-page application** with redirect URI `http://localhost:5000` (and later your real URL). Under **API permissions**, add `api://ota-admin/access`.

---

## 8.3 Validate admin tokens in FastAPI

**Do:** `app/auth/admin.py`:
- Fetch Microsoft's signing keys from `https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys` with `jwt.PyJWKClient` (it caches them).
- Decode with `audience="api://ota-admin"` (or the client ID, depending on token version) and `issuer="https://login.microsoftonline.com/<tenant>/v2.0"`.
- Read the `roles` claim (a list) and the user's `oid` / `preferred_username` for audit.
- A dependency `require(action)` that returns 403 if none of the user's roles allows it.

Replace the temporary `X-Admin-Key` dependency on every admin route with `require(...)`. Keep the dev key **only** when `env == "local"`.

**Check:** a unit test per role × endpoint. Generate test tokens with your own RSA key and point the validator at a fake JWKS in tests.

---

## 8.4 Idempotency keys

**Why:** if a network glitch makes the admin UI send "publish" twice, it must only happen once.

**Do:** a dependency for all admin POST/PATCH routes:
1. Require the header `Idempotency-Key: <uuid>`.
2. Look up `(actor_id, key)` in `idempotency_keys`:
   - found, same request hash → return the **stored** response;
   - found, different request hash → 422 (key reused for a different request);
   - not found → run the handler, then store status + body. Expire after 24 hours.

**Check:** send the same publish twice and get one publish and one `deployment_events` row.

---

## 8.5 Read endpoints

**Do:** `GET` endpoints with pagination (`?limit=50&cursor=...`, cursor = last seen `created_at,id`):
`/v1/admin/applications`, `/releases`, `/patches`, `/rollouts`, `/devices` (search by installation ID), `/audit-events`, `/deployment-events`.

---

## 8.6 Flutter Web admin console

**Do:**
1. Add `admin/` to the workspace: `flutter create --platforms=web admin`, then add `resolution: workspace` and list it in the root `pubspec.yaml`.
2. Login: use an MSAL-based package for Flutter Web (for example `aad_oauth`). Check that the package is maintained before choosing. Request the scope `api://ota-admin/access`.
3. Screens (keep them simple, using Material widgets):
   - Applications → Releases → Patches list
   - Patch detail: status, artifacts, **Validate** / **Publish** buttons
   - Rollout panel: current %, a slider that only moves up, **Pause** / **Resume**
   - **Rollback** and **Revoke** buttons. Revoke requires typing the patch number to confirm
   - Audit timeline
4. Hide buttons the user's roles don't allow. The server still enforces this, because hiding is only convenience.
5. Every mutation sends a fresh `Idempotency-Key` and an `X-Request-ID`.

**Run:** `cd admin && flutter run -d chrome --web-port 5000`.

---

## 8.7 Lock down the dev key

**Do:** the app refuses to start if `admin_dev_api_key` is set and `env` is not `local`.

---

## Phase 8 is done when

- [ ] A Viewer gets 403 on every mutation. A Publisher can run a full rollout
- [ ] Double-submitting any action has no double effect
- [ ] Every action appears in the audit timeline with the real user's name
