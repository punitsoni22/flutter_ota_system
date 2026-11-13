# Security policy

Flutter OTA System distributes code and configuration that apps run, so we take vulnerability reports
seriously. Flutter OTA System is **alpha software** and has **not been independently audited**. See
[docs/security.md](docs/security.md) for the threat model and known gaps.

## Supported versions

| Version | Supported |
|---|---|
| `0.1.x-alpha` and the unreleased bytecode architecture on `main` | Yes, best effort |
| anything older | No |

## Reporting a vulnerability

**Do not open a public GitHub issue, discussion or pull request for a vulnerability.**

Report it privately through **GitHub private vulnerability reporting**:

1. Go to the repository's **Security** tab → **Report a vulnerability**
   (`https://github.com/punitsoni22/flutter_ota_system/security/advisories/new`).
2. Include: the affected version/commit, component (backend, the `flutter_ota_system` SDK, the `flutter_ota` CLI, the toolchain or engine patch, the `ota` admin CLI, deploy), steps to
   reproduce or a proof of concept, impact, and any suggested fix.
3. Remove real secrets, tokens and personal data from logs before sending them.

If you cannot use GitHub, email **punitsoni14476@gmail.com** with the subject `[SECURITY] Flutter OTA System`. Do not
include working exploits for live third-party systems.

## What to expect

Best-effort targets from a small volunteer team. These are not guarantees:

- Acknowledgement within **5 business days**.
- An initial assessment within **14 days**.
- Fixes coordinated with you privately, then a GitHub Security Advisory with credit unless you
  ask otherwise.
- Please allow up to **90 days** before public disclosure, or less once a fix is released.

## Scope

In scope: the backend, `ota_client`, the CLI, the Docker/deploy configuration in this repo, and
the signing and verification protocol.

Out of scope: your own deployment's misconfiguration (e.g. default secrets used in production),
third-party services, social engineering, and denial of service by sheer volume against a
self-hosted instance. Reports about unsafe defaults are still welcome.

## Safe harbour

We will not pursue legal action for good-faith research that stays within this policy. That
means: test only against your own deployment, do not access other people's data, and give us
reasonable time to fix the issue before disclosure.
