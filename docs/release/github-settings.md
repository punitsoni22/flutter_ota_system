# GitHub repository settings (manual)

For maintainers of `punitsoni22/flutter_ota_system`. These settings live in GitHub, not in the
repository, so they must be changed by an admin in the web interface. GitHub occasionally renames
menus. Where a name differs, the older name is given in brackets.

The internal pre-publication audit (2026-11-11) found private vulnerability reporting **off** and
`main` **not protected**. Since then, `main` has been protected by a ruleset that requires a pull
request. Other settings could not be checked without admin access.

Do not treat a setting as enabled until you have checked it with the **Verify** step.

All security settings below are on one page: **Settings → Advanced Security** (older interface:
*Code security and analysis*).

## 1. Private vulnerability reporting (required before the release)

`SECURITY.md` and the issue template tell people to report vulnerabilities this way.

1. **Settings → Advanced Security → Private vulnerability reporting → Enable.**
2. In your own profile settings (**Settings → Notifications**), make sure security alerts reach an
   address you read.

**Verify:** the repository's **Security** tab shows a **Report a vulnerability** button, and
<https://api.github.com/repos/punitsoni22/flutter_ota_system/private-vulnerability-reporting>
returns `{"enabled": true}`.

## 2. Dependabot alerts and security updates

1. **Dependency graph:** enable it if it is not already on. It is normally on for public
   repositories.
2. **Dependabot alerts → Enable.**
3. **Dependabot security updates → Enable.** Dependabot then opens pull requests for vulnerable
   dependencies.
4. Version updates are configured in [`.github/dependabot.yml`](../../.github/dependabot.yml)
   (pip, pub, GitHub Actions, Docker, Docker Compose; weekly). Nothing to switch on: GitHub reads
   that file after it is pushed.

**Verify:**

- **Insights → Dependency graph → Dependabot** lists the five update jobs, without errors.
- The **Security → Dependabot** tab shows the alerts.

## 3. Secret scanning and push protection

1. **Secret Protection** (older interface: *Secret scanning*) **→ Enable.**
2. **Push protection → Enable.** It blocks pushes that contain recognised secrets.

**Verify:** **Security → Secret scanning** opens without asking to be enabled. A test push with a
fake token pattern is not needed.

## 4. Code scanning (CodeQL)

1. **Code scanning → CodeQL analysis → Set up → Default.**
2. Keep the detected languages: Python, JavaScript/TypeScript for the admin page, and GitHub
   Actions. Java/Kotlin needs a build and can stay off at first.
3. Query suite **Default**, then **Enable CodeQL**.

**Verify:** the **Actions** tab shows a finished *CodeQL* run, and **Security → Code scanning**
lists results (an empty list is fine).

## 5. Protect `main` (ruleset)

**Settings → Rules → Rulesets → New ruleset → New branch ruleset**:

1. **Name:** `main`. **Enforcement status:** Active.
2. **Target branches:** Add target → **Include default branch**.
3. Turn on:
   - **Restrict deletions**;
   - **Block force pushes**;
   - **Require a pull request before merging**. Set required approvals to 0 while there is a
     single maintainer: GitHub does not let you approve your own pull request, so 1 would block
     every merge. Raise it to 1 when there is a second maintainer, and turn on **Dismiss stale
     pull request approvals when new commits are pushed** at the same time;
   - **Require status checks to pass**, adding these CI checks:
     - `Secret scan (gitleaks, full history)`
     - `Backend (lint, tests, licences)`
     - `CLI (syntax + diff round trip)`
     - `Flutter (ota_client + example_app)`
     - `Docker build + local end-to-end smoke test`
     - `Shell scripts (shellcheck)`
4. **Bypass list:** add **Repository admin** only if you still want to push directly to `main`.
   Without it, every change goes through a pull request (recommended once the release is out).

**Verify:** a direct `git push` of a test commit to `main` is refused, or allowed only for the
bypass role. **Settings → Branches** shows `main` as protected.

## 6. GitHub Actions security

**Settings → Actions → General**:

1. **Actions permissions:** *Allow `punitsoni22`, and select non-`punitsoni22`, actions and
   reusable workflows*:
   - tick **Allow actions created by GitHub**;
   - under **Allow specified actions**, add `subosito/flutter-action@*`;
   - if offered, also tick **Require actions to be pinned to a full-length commit SHA**.
     The workflow already pins every action.
2. **Fork pull request workflows from outside collaborators:** **Require approval for
   first-time contributors** (or for all outside collaborators).
3. **Workflow permissions:**
   - choose **Read repository contents and packages permissions**;
   - untick **Allow GitHub Actions to create and approve pull requests**.
4. **Artifact and log retention:** for example 30 days. The CI uploads no artifacts and uses no
   secrets.

**Verify:** the next CI run passes. On the workflow run page, the `GITHUB_TOKEN` permissions show
`Contents: read` only.

## 7. Repository page and labels

- **About** (gear icon on the main page):
  - **Description:** "An experimental, self-hosted, open-source OTA update platform for Flutter
    applications."
  - **Topics:** `flutter`, `flutter-ota`, `dart`, `code-push`, `over-the-air-updates`,
    `self-hosted`, `open-source`, `fastapi`, `docker`, `mobile-devops`.
  - **Website:** leave empty (there is no hosted service).
- **Issues → Labels → New label.** GitHub's defaults already include `bug`, `enhancement`,
  `documentation`, `help wanted` and `good first issue`. Add:
  - `needs-triage`: the issue forms apply it automatically;
  - `flutter`, `android`, `backend`, `patch-engine`, `security`, `compatibility`.
- **Settings → General → Features:** keep **Issues** on. Enable **Discussions** only if you will
  answer them.

## 8. Before creating the release

1. Push the release-preparation commit, then wait for CI to be green.
2. Create the tag `v0.1.0-alpha.1` on that commit.
3. Create the GitHub release from the tag:
   - tick **Set as a pre-release**;
   - use [v0.1.0-alpha.1.md](v0.1.0-alpha.1.md) as the text, with links changed to absolute
     GitHub URLs.
