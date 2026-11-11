# Pre-publication audit: Flutter OTA System v0.1.0-alpha

- **Date:** 2026-11-11.
- **Commit audited:** `c75bdea`, identical on this machine and on GitHub (`punitsoni22/flutter_ota_system`).
- **Status:** the repository is **already public** (pushed earlier), so this audit covers what is already published.

## Overall readiness

| Area | Result |
|---|---|
| Secrets and private data (files, all history, branches, tags) | ✅ None found |
| Licensing | ✅ No unresolved issue |
| Installation (fresh Linux install from the public repository) | ✅ All tested steps passed |
| Branding (Flutter OTA System) | ✅ Consistent; remaining "punit" text is intentional (see below) |
| Platform statements | ✅ Consistent everywhere |
| GitHub security settings | ⚠️ **Private vulnerability reporting is OFF**, although SECURITY.md relies on it (fix A1) |
| Known bugs | ⚠️ Fixed on `main` but only lightly validated; 3 low-priority bugs open (disclose, see B) |

**Verdict:** category A has **one** item (A1, a GitHub setting). After A1 the repository is fit for a
public **experimental alpha** release, with the category B disclosures below. It is **not**
production-ready.

## 1. Security and privacy findings

**Scope:** working tree, all 18 commits on all refs (`main` only; no other branches, no tags, no
stash), a fresh anonymous clone of the GitHub repository, the CI workflow, Docker and env files.

| Check | Result |
|---|---|
| gitleaks v8.21.2, all history (local and the public clone) | No leaks |
| gitleaks, working tree | No leaks |
| Private names list (company, internal hosts, old server; 5 patterns), every version of every file | 0 matches |
| Files ever committed: `.env`, keys, certificates, keystores, dumps, databases, logs | None (only `.env.example` and `deploy/.env.example`, with placeholder values) |
| Private key material (`BEGIN … PRIVATE KEY`) | None; only two old doc pages that *describe* the key format |
| Internal URLs | None. Render/Supabase appear only as placeholders (`<your-service>.onrender.com`, `<ref>.supabase.co`) plus Supabase's generic regional host |
| IP addresses | `10.0.2.2` (Android emulator) and `192.168.1.23` (example in a doc) only |
| Device or customer data | None (only made-up ids such as `docs-example-0001`) |
| Commit identities | Only `Punit Maintainers <punitsoni22@users.noreply.github.com>`; no tool attribution in messages |
| CI workflow | `pull_request` (not `pull_request_target`), read-only token, no secrets used, no artifacts uploaded; passing on all 3 pushes |
| Docker | `.dockerignore` files exclude `.env`, keys, dumps and backups; images are built locally and never published |

**No exposed credential was found, so no key needs rotating because of this repository, and no
history rewrite is needed.**

Not secrets, but worth knowing:

- **Personal email:** SECURITY.md and CODE_OF_CONDUCT.md publish the maintainer's personal Gmail
  address as the contact (intentional). Consider a dedicated address.
- **ChatGPT reference:** `THIRD_PARTY_NOTICES.md` line 24 says the roadmap was written from
  "research reports generated with ChatGPT Deep Research (not published here)", a reference to
  material readers cannot see. The same phrase is in the history copy of the original
  `IMPLEMENTATION_PLAN.md`. Recommended: reword line 24. A history rewrite is not needed (nothing
  sensitive).
- **Old hosted test server:** outside the repository, the maintainer's shell still points
  `OTA_API_URL` at it. If that Render deployment still runs, shut it down or rotate its admin key
  and signing key. It is no longer documented anywhere.
- **Private rotation checklist:** the private `SECRET_ROTATION_CHECKLIST.md` (in `.local/`, not
  published) still needs to be worked through by the maintainer. It covers secrets from the old
  private setup, not this repository.

## 2. Licence findings

| Item | Result |
|---|---|
| `LICENSE` | Identical to the official Apache-2.0 text |
| `NOTICE` | Present: product name, "Copyright 2026 The Punit Authors", bsdiff and Flutter-template credits |
| `THIRD_PARTY_NOTICES.md` | Present; Python, Dart and CI dependencies with licences; bsdiff BSD-2-Clause and Flutter BSD-3-Clause texts |
| Source headers | SPDX `Apache-2.0` with "The Punit Authors" (owner's decision) |
| Shorebird | No Shorebird code; it is referenced as prior art only |
| Flutter engine | Not modified or redistributed; code patches use stock Flutter's loader option |
| Icons | Original artwork (`docs/assets/make_icon.py`), no Flutter or third-party logo material |
| psycopg (LGPL-3.0) | Only installed when you build the image locally. If Docker images are ever **published**, ship the LGPL texts in them (THIRD_PARTY_NOTICES §7) |
| Redistribution restrictions | None unresolved |

## 3. Installation test results (executed in this audit)

Test setup:

- a fresh clone of the **public** GitHub repository, with no `.env`;
- Linux, Docker 29.1 and Compose 2.40;
- its own project name and ports (`fos-audit`, 18000/18080);
- an Android 13 phone (arm64-v8a) over USB using `adb reverse`.

| Step | Result | Evidence |
|---|---|---|
| Fresh setup (`./flutter-ota-system.sh setup`) | ✅ PASS | `.env` created with random local secrets; dev key created; API, admin page and file server healthy |
| PostgreSQL initialisation | ✅ PASS | Migrations at `0003`, 11 tables |
| Backend health | ✅ PASS | `/health/ready` OK; all three services healthy |
| Admin dashboard | ✅ PASS | `/admin` returns 200; admin API: correct key 200, wrong key 401 |
| Demo app configuration (KI-5) | ✅ PASS | The example app built **without** `OTA_APP` registered as `flutter-ota-system-demo` |
| Device registration, update check | ✅ PASS | `verify_demo.sh` (32 checks) and the phone |
| Release creation, patch publishing | ✅ PASS | `demo` and `ota patch create … --channel dev` |
| Artifact download, SHA-256, ES256 signature | ✅ PASS | `verify_demo.sh`, including tampered-file and wrong-key rejections |
| Patch activation on a device | ✅ PASS | Phone screen showed "Active patch #3" after a restart; server: downloaded, staged, boot succeeded; device reports patch 3 |
| Persistence | ✅ PASS | Same signing-key hash and same row counts after `stop`/`up` and `down`/`up`; `verify` passed again |
| CLI install (`./flutter-ota-system.sh cli`) | ✅ PASS | `ota app list` worked even with a bogus `OTA_API_URL` in the shell |
| Reset safety | ✅ PASS | Wrong confirmation word: nothing deleted; correct word: only that project removed |

Also tested earlier on 2026-11-11 and not re-run here:

- **Code patches** (`ota release android` / `ota patch android`) on the phone: activation, crash
  fallback, rollback, policy gate and asset refusal.
- **KI-1** on the phone.
- **Backup and restore**, including KI-12.
- The full `prepublish_check.sh`, with the end-to-end demo (59 checks).

**Not tested:** macOS, Windows, iOS, emulators, the single-server `deploy/` setup, upgrades
between released versions, load and scale.

## 4. Known bugs

| Issue | Classification |
|---|---|
| 1. Deleted and re-created release breaks installs (KI-1) | **Fixed and tested** (unit tests and one Android phone). Was a production blocker; still needs wider validation |
| 2. Policy-approval reason not saved (KI-2) | **Fixed and tested** (backend test, migration on a real database) |
| 3. Channels only via the API (KI-3) | **Known limitation** (accepted for the alpha) |
| 4. Promotion checks only in the CLI (KI-4) | **Fixed and tested** (server enforces; backend test, browser, CLI). Was a production blocker; still needs wider validation |
| 5. Demo slug mismatch (KI-5) | **Fixed and tested** (verified again in this audit) |
| 6. 30-minute polling documentation (KI-6) | **Fixed** (docs say there is no timer) |
| KI-7 CLI broke with `bsdiff4` 1.4.2 | **Fixed and tested** (bsdiff4 1.2.6 to 1.4.2, Dart reader, real code patch) |
| KI-9 wrong admin-page key hint | **Fixed** |
| KI-12 damaged backups reported as OK | **Fixed and tested** |
| KI-8 empty draft after a failed `ota patch android` | **Open bug** (low) |
| KI-10 stale display after rollback | **Open bug** (low, cosmetic) |
| KI-11 `/health/ready` returns 500, not 503, while the DB is down | **Open bug** (low) |

There is **no production blocker among the known bugs**. Production use is still not supported
(see B).

## 5. Platform testing status

`README.md`, `docs/limitations.md` and `docs/release/v0.1.0-alpha.md` carry the identical table.
No document claims cross-platform support or production compatibility.

| Platform | Verified status |
|---|---|
| Linux development environment | Internally tested |
| Android Flutter application | Internally tested |
| iOS | Not tested |
| macOS | Not tested |
| Windows | Not tested |

## 6. GitHub configuration (manual, in the repository settings)

Checked through the public GitHub API where possible; everything else cannot be read without admin
access and must be checked by the owner.

| Setting | Status | Action |
|---|---|---|
| Private vulnerability reporting | ❌ **Off** (API: `enabled: false`) | **A1:** Settings → Security → Private vulnerability reporting → Enable |
| SECURITY.md | ✅ Present | Works fully once A1 is done |
| Issue templates, PR template | ✅ Present (bug, feature, security link) | — |
| Branch protection for `main` | ❌ Not protected | Add a rule or ruleset: require a PR, the CI checks, no force-push, no deletion |
| Dependabot alerts / security updates | ? Not verifiable | Settings → Security: enable both. There is no `.github/dependabot.yml`; add one for pip, pub, GitHub Actions and Docker |
| Secret scanning, push protection | ? Not verifiable | Settings → Security: make sure both are on (normally on for public repositories) |
| Code scanning (CodeQL) | ❌ Not set up | Settings → Security → Code scanning → Default setup (Python, JavaScript; Java/Kotlin optional) |
| Actions permissions | ? Not verifiable | Settings → Actions: default token read-only; require approval for first-time contributors; allow only GitHub and verified actions. Pin `subosito/flutter-action` (third-party) to a commit SHA |
| Actions logs and artifacts | ✅ No secrets used, no artifacts uploaded | Set log retention as wanted |
| Repository description and topics | Empty | Description: "Self-hosted Flutter OTA update platform (experimental)"; topics such as flutter, ota, code-push, self-hosted |

## 7. Remaining blockers

**A. Must fix before (further) publication**

- **A1:** enable private vulnerability reporting. SECURITY.md and the issue-template link point to
  it, so the documented security channel is currently broken (only the email fallback works).
- No exposed secrets, legal restrictions or private data were found.

**B. Must disclose before alpha testing** (all are already in the docs; the release notes should
link them):

- Experimental, internally tested only; no production-scale validation and no load tests.
- iOS, macOS and Windows not tested; Android tested on a small number of devices.
- The release-identity (KI-1) and promotion-safety (KI-4) fixes are new and tested on one device.
- Open bugs KI-8, KI-10 and KI-11; KI-3 limitation.
- Missing production features: one shared admin key, no roles, no audit log, signing key stored as
  a file, single-server `deploy/` setup not verified.
- `dev.flutterota.*` application ID: ownership of `flutterota.dev` not confirmed.

**Release paperwork before tagging:**

- `CHANGELOG.md` still has `[0.1.0-alpha] - YYYY-MM-DD`, with the fixes listed under
  `[Unreleased]` above it. Since 0.1.0-alpha was never tagged, merge `[Unreleased]` into
  `[0.1.0-alpha]` and set the date.
- In `docs/known-issues.md`, change "Fixed (Unreleased)" to "Fixed in 0.1.0-alpha".
- Link `docs/known-issues.md` from `docs/release/v0.1.0-alpha.md`.

## 8. Proposed experimental-use warning (for approval)

For the top of the GitHub release:

> ⚠️ **Experimental alpha. Do not use for production OTA delivery.** Flutter OTA System v0.1.0-alpha
> has been tested internally on Linux (server, Docker) and Android only, on a small number of
> devices. iOS, macOS and Windows have not been tested. It has no independent security audit and
> no load tests. Code patches change what runs inside your users' apps: test every patch on your
> own devices first, and read the [known issues](known-issues.md) and
> [limitations](limitations.md). Self-hosted only; you run it at your own risk (Apache-2.0,
> sections 7 and 8).

## 9. Recommended next actions

1. **A1:** enable private vulnerability reporting (manual).
2. Enable Dependabot alerts and updates, secret scanning, push protection and CodeQL; protect
   `main`; set the Actions permissions; add the description and topics (manual).
3. Reword `THIRD_PARTY_NOTICES.md` line 24 (ChatGPT reference), and do the release paperwork
   above.
4. Optional: add `.github/dependabot.yml`; pin `subosito/flutter-action` to a commit SHA;
   consider a dedicated contact email.
5. Outside the repository: shut down or rotate the old Render test server; work through the
   private secret-rotation checklist; confirm `flutterota.dev` ownership.
6. Then create the `v0.1.0-alpha` tag as a **pre-release**, with the warning above.

## Follow-up (release preparation, same day)

Done locally after this audit (not yet pushed):

- **Release paperwork:** CHANGELOG has a dated `0.1.0-alpha.1` section; known-issues says
  "Fixed in v0.1.0-alpha.1"; versions are aligned to 0.1.0-alpha.1 (CLI `0.1.0a1`); the release
  notes are in [release/v0.1.0-alpha.1.md](release/v0.1.0-alpha.1.md).
- **ChatGPT reference** removed from `THIRD_PARTY_NOTICES.md`.
- **Dependabot:** `.github/dependabot.yml` added.
- **CI:** actions pinned to full commit SHAs and the gitleaks image to its digest; checkouts no
  longer store the token.
- **GitHub settings:** step-by-step instructions are in
  [release/github-settings.md](release/github-settings.md).

Still open: A1 (enable private vulnerability reporting) and the other GitHub settings. They are
manual.
