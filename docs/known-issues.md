# Known issues

Bugs and gaps found while preparing and testing **v0.1.0-alpha.1**. Each entry is written so it
can be copied into an issue. The fixes marked "Fixed in v0.1.0-alpha.1" are part of that release
(see the [CHANGELOG](../CHANGELOG.md)); new reports go to the
[issue tracker](https://github.com/punitsoni22/flutter_ota_system/issues).

| ID | Title | Type | Priority | Status |
|---|---|---|---|---|
| [KI-4](#ki-4-promote-safety-checks-are-enforced-only-by-the-cli) | Promote safety checks are enforced only by the CLI | Bug (safety) | **Critical** | ✅ Fixed in v0.1.0-alpha.1 |
| [KI-1](#ki-1-re-creating-a-deleted-release-breaks-existing-installs) | Re-creating a deleted release breaks existing installs | Bug | **High** | ✅ Fixed in v0.1.0-alpha.1 |
| [KI-7](#ki-7-the-cli-breaks-with-bsdiff4-142) | The CLI breaks with `bsdiff4` 1.4.2 | Bug (dependency) | High | ✅ Fixed in v0.1.0-alpha.1 |
| [KI-2](#ki-2-the-policy-approval-reason-is-not-stored) | The policy-approval reason is not stored | Bug | Medium | ✅ Fixed in v0.1.0-alpha.1 |
| [KI-5](#ki-5-example-app-and-demo-scripts-use-different-app-slugs) | Example app and demo scripts use different app slugs | Bug (demo) | Low | ✅ Fixed in v0.1.0-alpha.1 |
| [KI-8](#ki-8-a-failed-ota-patch-android-leaves-an-empty-draft-patch) | A failed `ota patch android` leaves an empty draft patch | Bug | Low | Open |
| [KI-9](#ki-9-admin-page-shows-the-wrong-default-key) | Admin page shows the wrong default key | Bug (UI text) | Low | ✅ Fixed in v0.1.0-alpha.1 |
| [KI-10](#ki-10-stale-patch-display-after-rollback) | Stale patch display after rollback | Bug (UI) | Low | Open |
| [KI-11](#ki-11-healthready-returns-500-instead-of-503-while-the-database-is-down) | `/health/ready` returns 500 instead of 503 while the database is down | Bug | Low | Open |
| [KI-12](#ki-12-backup-could-write-a-damaged-archive) | `backup` could write a damaged archive | Bug (data safety) | High | ✅ Fixed in v0.1.0-alpha.1 |
| [KI-3](#ki-3-channels-can-be-created-only-through-the-api) | Channels can be created only through the API | Limitation | Low | Accepted for v0.1.0-alpha.1 |
| [KI-6](#ki-6-old-docs-described-a-30-minute-background-check) | Old docs described a 30-minute background check | Docs bug | — | ✅ Fixed in the docs |

KI-1 and KI-4 were the known blockers for production use. Their fixes still need wider testing,
and production use is not supported in v0.1.0-alpha.1 anyway ([limitations.md](limitations.md)).

---

## KI-4: Promote safety checks are enforced only by the CLI

> ✅ **Fixed in v0.1.0-alpha.1.** The server now enforces the checks for protected channels
> (`OTA_PROTECTED_CHANNELS`, default `production`) on `publish` and `rollout`, for every client.
> `force: true` with a `reason` overrides them and is logged. The CLI (`--force --reason`) and the
> admin page (asks for a typed reason) use it. Tested: backend test, admin page in a browser, CLI.
> See [rollouts.md](rollouts.md). The text below describes the original bug.

**Priority:** Critical.

**Current behaviour.** `ota patch promote` refuses to move a patch to another channel when it is
not live on the source channel (default `staging`) or has boot failures, unless `--force` is
passed ([`cli/ota.py`](../cli/ota.py), `patch_promote`). The server does not check either rule:
`POST /v1/admin/patches/{id}/publish` and `POST /v1/admin/patches/{id}/rollout` accept any
channel and percentage from any admin-key holder. So the checks are bypassed by:

- `ota patch publish <id> --channel production` or `ota patch rollout <id> --channel production`;
- `ota patch android … --channel production` (publishes straight to production);
- the admin page (its promote button only warns);
- any direct API call or script.

**Expected behaviour.** Safety and compatibility rules for production are enforced by the
backend, for every client. The CLI keeps its checks only as early, friendly errors.

**Proposed fix** (backend logic change, needs separate approval):

1. Add a setting for protected channels, e.g. `OTA_PROTECTED_CHANNELS=production`.
2. In `publish_patch` and `change_rollout`, when the target channel is protected and the new
   percentage is above 0, refuse with `409 promotion_checks_failed` unless:
   - the patch is, or was, deployed on a non-protected channel with a percentage above 0; and
   - its `patch_boot_failed` count is 0.
3. Allow an explicit override only with `force: true` **and** a `reason` in the request, and
   record who/when/why once an audit log exists (see [security.md](security.md)).
4. Make the CLI and admin page send `force`/`reason` instead of deciding locally.
5. Lowering a percentage, rolling back and revoking stay unrestricted (they are the emergency
   path).

**Tests to add:** publish to `production` without a staging deployment → 409; with boot failures
→ 409; after a clean staging deployment → 200; `force` without `reason` → 422; with both → 200;
rollout to 0% always allowed; `patch android --channel production` refused.

---

## KI-1: Re-creating a deleted release breaks existing installs

> ✅ **Fixed in v0.1.0-alpha.1.** The client now switches to a re-created release by itself: it drops
> the old release's patches and resets anti-replay, but never goes back to a retired release id.
> The server refuses to register a version again that devices still report, unless `replace: true`
> (CLI `--replace`). Tested: client and backend tests, and on an Android phone: a release was
> deleted and re-registered with `--replace` while the app ran a patch; the app dropped the old
> patch, returned to the store code, then accepted and ran patch #1 of the re-created release.
> The text below describes the original bug.

**Priority:** High. Must be fixed and tested before production use.

**Current behaviour.** The client stores the server's `release_id` the first time it sees it and
refuses any later response with another id for the same store version
([`ota_client.dart`](../packages/ota_client/lib/src/ota_client.dart), `_checkIdentity`). When a
release is deleted (`ota release delete`) and the same version is registered again, it gets a new
id. Every existing install of that version then rejects **all** patches with
`release id changed`, until the app is reinstalled or updated from the store.

**Steps to reproduce:** register `1.0.0+1`, run the app once, `ota release delete <app> --version
1.0.0+1`, register `1.0.0+1` again, publish a patch, check from the app → `rejected: release id
changed`.

**Proposed fix** (needs separate approval; touches client and backend logic):

1. **Server:** refuse to re-create a version that devices have already reported, unless the admin
   confirms it (`--replace`), and print what will happen to existing installs. Prefer giving a
   rebuilt store build a new build number; the docs already recommend this.
2. **Client:** when the server reports a different `release_id` for the same version, treat it
   like a store update: clear the staged/active patch state and the anti-replay counter for that
   release (`resetForNewRelease`), accept the new id, and record an event. Signatures still bind
   every patch to its release id, so patches for the old release stay unusable.
3. Document the final behaviour in [troubleshooting.md](troubleshooting.md).

**Tests to add:** client unit test for the id change (state reset, new patch accepted, old patch
rejected); backend test for the re-create refusal; end-to-end run of the reproduction above.

---

## KI-2: The policy-approval reason is not stored

> ✅ **Fixed in v0.1.0-alpha.1.** Every approval and withdrawal is stored with its reason and time
> (migration 0003; apps approved earlier get one "reason unknown" record). `AppOut` shows the
> latest; `GET /v1/admin/apps/{slug}/policy-approvals` and `ota app policy-history` list them.
> Who approved is still not recorded (one shared admin key). The text below describes the
> original bug.

**Priority:** Medium. Fix before claiming the policy gate is complete.

**Current behaviour.** `ota app approve-policy <app> --reason "…"` (and
`POST /v1/admin/apps/{slug}/policy-approval`) requires a reason of 3–1000 characters, but the
server only flips the `aot_policy_approved` flag. The reason, the time and who approved are not
saved anywhere, so there is no record of why code patches were allowed for a store app.

**Current limitation (documented):** treat the approval as a switch only; keep your own record of
the review outside Flutter OTA System ([cli-reference.md](cli-reference.md), [api-reference.md](api-reference.md),
[security.md](security.md)).

**Proposed fix** (database schema change, needs separate approval): store each approval or
revocation (reason, time, approver once admin identities exist) in a new table or new columns via
an Alembic migration; return the latest one in `AppOut`; show it in `ota app list` and the admin
page.

**Tests to add:** approve with a reason → reason and time returned; revoke → history kept;
migration upgrade on an existing database.

---

## KI-5: Example app and demo scripts use different app slugs

**Priority:** Low. **Status:** ✅ Fixed in v0.1.0-alpha.1: the example app (then `example_app/`, now
`packages/ota_client/example/`) defaults `OTA_APP` to
`flutter-ota-system-demo`; tested on a phone without an `OTA_APP` define (registered, no 404).

**Behaviour before the fix.** `example_app` defaulted to `OTA_APP=demo`
([`main.dart`](../packages/ota_client/example/lib/main.dart)), while `scripts/seed_demo.sh` and the demo create the
app `flutter-ota-system-demo`. Following the scripts without `--dart-define=OTA_APP=flutter-ota-system-demo` gave
`register failed: HTTP 404 {"detail":"Unknown application"}`.

**Proposed fix:** use one slug everywhere (example app default, scripts, docs) and run the whole
demo workflow ([installation.md](installation.md)) to confirm it.

---

## KI-3: Channels can be created only through the API

**Priority:** Low. Accepted limitation for v0.1.0-alpha.1.

`production`, `staging` and `dev` exist for every app. Other channels are created with the admin
API; there is no CLI command or admin-page control, and channels cannot be renamed or deleted:

```bash
curl -X POST -H "X-API-Key: $OTA_API_KEY" -F name=qa "$OTA_API_URL/v1/admin/apps/<slug>/channels"
```

Details: [rollouts.md](rollouts.md). **Future improvement:** channel management in the CLI and the
admin page.

---

## KI-6: Old docs described a 30-minute background check

**Status:** Fixed in the documentation. No code change.

Earlier guides said the app checks "every 30 minutes while open". The client has **no timer**: it
checks only when the app calls `checkForUpdate()`, and the server's `next_check_after_seconds`
(default 1800 s, setting `OTA_CHECK_INTERVAL_SECONDS`) only makes earlier calls return
`checked recently`. A polling timer will not be added just to match the old text. Current
behaviour: [flutter-integration.md](flutter-integration.md#activation).

---

## KI-7: The CLI breaks with `bsdiff4` 1.4.2

> ✅ **Fixed in v0.1.0-alpha.1.** `cli/otadiff.py` now uses only the public `bsdiff4.diff()` and
> `bsdiff4.patch()` and converts the standard BSDIFF40 format itself. Output is unchanged
> (byte-identical with 1.4.1). Tested with bsdiff4 1.2.6, 1.3.2, 1.4.0, 1.4.1 and 1.4.2, the Dart
> reader, and a real `ota patch android` run with 1.4.2. The requirement is now `bsdiff4>=1.2.6`,
> and CI checks the oldest and newest. The text below describes the original bug.

**Priority:** High (it breaks `ota patch android`). **Workaround in place:** version pin.

**Current behaviour.** [`cli/otadiff.py`](../cli/otadiff.py) uses internal helpers of the
`bsdiff4` package (`bsdiff4.format.unpack_control_block`, `pack_control_block`, `write_patch`).
Found while testing the packaged CLI on a fresh install:

| `bsdiff4` | OTADIF01 round trip |
|---|---|
| 1.2.6, 1.3.2 | Fails: `bsdiff4.format` has no `unpack_control_block` |
| 1.4.0, 1.4.1 | Passes |
| 1.4.2 (newest at the time of testing) | Fails: `write_patch() takes 4 positional arguments but 5 were given` |

With the old requirement `bsdiff4>=1.2`, a fresh install picked 1.4.2, so every Android code patch
would fail at the diff check, and the CI round-trip test would fail too.

**Workaround (applied).** `cli/requirements.txt` and `cli/pyproject.toml` require
`bsdiff4>=1.4.0,<1.4.2`.

**Proposed fix** (CLI code change, needs separate approval): stop depending on `bsdiff4`
internals. For example, write the OTADIF01 container from the public `bsdiff4.diff()` output by
parsing its documented `BSDIFF40` layout, or vendor the small control-block helpers. Then test
the round trip against several `bsdiff4` versions in CI.

---

## KI-8: A failed `ota patch android` leaves an empty draft patch

**Priority:** Low. **Status:** Open.

`ota patch android` creates the patch first and then uploads one diff per ABI. If it stops in
between (for example the KI-7 crash, or a network error), the patch stays as a **draft without
artifacts**: its number is used up, and publishing it fails with `422 Patch has no artifacts`.
Seen in testing (draft patch #1 of a test app).

**Workaround:** ignore it, or revoke it (`ota patch revoke <id> --yes`) to keep the list tidy.

**Proposed fix:** compute and check all diffs before creating the patch, and delete or revoke the
draft when an upload fails (a `DELETE` for draft patches would be needed).

---

## KI-9: Admin page shows the wrong default key

**Priority:** Low. **Status:** ✅ Fixed in v0.1.0-alpha.1: the page now points to `OTA_ADMIN_API_KEY` in `.env`.

Before you connect, the admin page said the default key for local Docker is `dev-admin-key`.
The local stack actually uses `OTA_ADMIN_API_KEY` from `.env` (`local-dev-admin-key-not-a-secret`
in `.env.example`). **Fix:** change the text in `backend/app/admin.html` to "the
`OTA_ADMIN_API_KEY` value from your `.env`".

---

## KI-10: Stale patch display after rollback

**Priority:** Low (cosmetic). **Status:** Open.

- Admin page: a rolled-back patch still shows its old rollout (e.g. `staging 100%`,
  `production 50%`) in the **Rollout** column. The channel summary at the top is correct.
- Example app: between a rollback (or revoke) and the next restart, "Active patch" shows `none`
  although the old patch is still running until the restart.

**Proposed fix:** show rolled-back deployments as inactive in the admin page; in the example app,
label the state "rolled back, restart to apply".

---

## KI-11: `/health/ready` returns 500 instead of 503 while the database is down

**Priority:** Low. **Status:** Open.

Found while testing recovery: after restarting only the Postgres container, `/health/ready`
answered `500` a few times, then `200` once the database was back. A readiness check should
answer `503 Service Unavailable` with a short message, so load balancers and monitors can tell
"not ready" from a crash. The backend did reconnect by itself. **Fix:** catch the database error in
the readiness handler and return 503.

---

## KI-12: `backup` could write a damaged archive

**Priority:** High (data safety). **Status:** ✅ Fixed in v0.1.0-alpha.1.

Found while testing the rename upgrade. `backup` streams the patch files and signing key out of a
one-off API container into `files.tgz`. When the API image did not exist yet, Docker Compose built
it first and printed the build log into that file. The backup still reported success, because
its checksum was taken of the damaged file, and `restore` deleted the existing files before it
found the archive was unreadable.

**Fix:** `backup` builds the image first (log to the terminal) and then checks its result: the
database dump must be a `pg_dump` archive and `files.tgz` a valid gzip tar that contains the signing
key. `restore` runs the same checks **before** changing anything and refuses a damaged backup.
Tested: a damaged backup is refused with "Nothing was changed"; a good backup restores the same
data and the identical signing key.

