# Manual security checklist (before and right after going public)

`./scripts/prepublish_check.sh` automates the technical checks: secret scan, forbidden names,
tests and the demo. This list covers what a script cannot do. A maintainer must do each item by
hand and tick it.

Private details (which credentials existed, old server addresses) live only in the maintainer's
git-ignored `.local/release/` folder. **Never copy them into this file.**

Do sections A–C **before** the first push, section D **during** the release, and section E
**after** it.

## A. Secret rotation

Assume every credential that ever existed in the old private repository, in a chat, a screenshot
or a CI log is exposed.

- [ ] Go through `.local/release/SECRET_ROTATION_CHECKLIST.md` line by line.
- [ ] **Admin API keys:** generate new ones on every server that still runs. Confirm an old key
      now gets `401`.
- [ ] **JWT / device-token secret:** replace it. Existing devices simply re-register.
- [ ] **Database passwords:** change them on every database that still runs.
- [ ] **Object storage keys** (S3-compatible, Azure, ...): revoke the old keys and create new ones.
- [ ] **Hosting / CI tokens** (deploy hooks, cloud API tokens, GitHub personal access tokens,
      Actions secrets): revoke them, and create new ones only where still needed.
- [ ] **Patch-signing keys (ES256):** if a private signing key ever left a secure machine, stop
      using it. Devices trust the *public* key built into the app, so a new key needs a new
      store release of each app that used the old one.
- [ ] **Old servers:** shut down, or move to new credentials, any server whose address appeared
      in the private history.
- [ ] Write the date of each rotation in the private checklist (not here).

## B. Repository content

- [ ] `./scripts/prepublish_check.sh` passes on a **fresh clone** of exactly what will be pushed.
- [ ] `.local/forbidden-patterns.txt` contains every internal name, domain, email and old URL.
- [ ] `git log --format='%an <%ae> | %cn <%ce>' | sort -u` shows only the public maintainer
      identity (a `users.noreply.github.com` address).
- [ ] `git remote -v` points to the **public** repository, from the public folder. The private
      archive is never pushed anywhere.
- [ ] No pre-built Docker image is published (see
      [THIRD_PARTY_NOTICES.md §7](../../THIRD_PARTY_NOTICES.md#7-future-actions-before-publishing-pre-built-docker-images)).

## C. GitHub account and repository settings

These are done on github.com by the maintainer.

- [ ] Two-factor authentication is on for the maintainer account.
- [ ] **Private vulnerability reporting** is on: *repository → Settings → Security (Advanced
      Security / Code security) → Private vulnerability reporting → Enable*.
- [ ] Test it: open *Security → Report a vulnerability* from a second account (or ask a
      friend), check that it arrives, then close it.
- [ ] The e-mail address in [SECURITY.md](../../SECURITY.md) is monitored, and a test mail
      arrives.
- [ ] **Secret scanning** and **push protection** are on (same settings page; free for public
      repos).
- [ ] **Dependabot alerts** and **Dependabot security updates** are on.
- [ ] *Settings → Actions → General*:
  - *Workflow permissions* = **Read repository contents**.
  - Approval is required for workflows from first-time contributors' forks.
- [ ] A ruleset or branch protection on `main`: require a pull request, require the CI checks to
      pass, and block force pushes and deletion. Set this up after the first push, because the
      first push goes straight to `main`.
- [ ] Optional hardening: pin the GitHub Actions in `.github/workflows/ci.yml` to commit SHAs
      instead of tags (`@v4`).

## D. Release

- [ ] The tag `v0.1.0-alpha.1` is created as a **pre-release**, with
      [v0.1.0-alpha.1.md](v0.1.0-alpha.1.md) as its notes.
- [ ] The release says clearly: alpha, not production-ready, self-hosted only.
- [ ] No binaries, keys or `.env` files are attached to the release.

## E. After publishing (first days)

- [ ] *Security* tab: no secret-scanning alerts. If one appears, rotate that secret first, then
      investigate.
- [ ] *Security → Dependabot*: review any alerts.
- [ ] Clone the public repo on another machine and follow the README quickstart only.
- [ ] Keep watching the security contact (GitHub reports and e-mail).
