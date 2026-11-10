# Punit documentation

Punit is an experimental, self-hosted over-the-air (OTA) patch system for Flutter apps. Start with
the [README](../README.md) for an overview. The pages below are grouped by what you want to do.

> [!NOTE]
> **Testing status.** Punit has been tested internally on a **Linux** development machine and
> Docker backend, and with **Android** Flutter apps only (a small number of devices). iOS, macOS
> and Windows are **not tested**. Code that may support a platform is not the same as a tested
> platform. See
> [Platform Support & Testing Status](../README.md#platform-support--testing-status) and
> [limitations.md](limitations.md#platform-limitations).

## Learn (tutorial)

| Page | You will |
|---|---|
| [installation.md](installation.md) | Run the server locally with Docker, publish a test patch and see it in the example app |

## Do a task (how-to guides)

| Page | Task |
|---|---|
| [flutter-integration.md](flutter-integration.md) | Add `ota_client` to your Flutter app |
| [releases-and-patches.md](releases-and-patches.md) | Register a store release, build and publish patches |
| [rollouts.md](rollouts.md) | Go from staging to 1% → 100%, roll back, revoke |
| [operations.md](operations.md) | Deploy a server, monitor it, back it up, recover |
| [troubleshooting.md](troubleshooting.md) | Fix common problems |

## Look something up (reference)

| Page | Contents |
|---|---|
| [api-reference.md](api-reference.md) | Every HTTP endpoint, with requests, responses and errors |
| [cli-reference.md](cli-reference.md) | Every `ota` command and local script |
| [configuration.md](configuration.md) | Every environment variable and build setting |

## Understand (explanation)

| Page | Contents |
|---|---|
| [concepts.md](concepts.md) | Releases, patches, compatibility, channels, rollouts, rollback, revocation |
| [architecture.md](architecture.md) | Control plane, data plane and on-device runtime; flows and database |
| [security.md](security.md) | Security model, implemented vs planned controls, threat model |
| [limitations.md](limitations.md) | What is tested, experimental, planned or unsupported |
| [known-issues.md](known-issues.md) | Known bugs, with priority and proposed fixes |
| [roadmap/](roadmap/README.md) | Implemented, partial and planned work by phase |
| [adr/](adr/README.md) | Architecture decision records |

## Project

| Page | Contents |
|---|---|
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Development setup, tests, pull requests |
| [SECURITY.md](../SECURITY.md) | Reporting vulnerabilities privately |
| [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) | Community rules |
| [release/](release/v0.1.0-alpha.md) | Release notes and pre-publish checklists |

All documentation describes **v0.1.0-alpha**. Where a page and the code disagree, the code is
correct; please open an issue.
