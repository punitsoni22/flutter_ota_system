# Flutter OTA System documentation

Flutter OTA System is an experimental, self-hosted over-the-air (OTA) patch system for Flutter apps. Start with
the [README](../README.md) for an overview. The pages below are grouped by what you want to do.

> [!NOTE]
> **Testing status.** Flutter OTA System has been tested internally on a **Linux** development machine and
> Docker backend, and with **Android** Flutter apps only (a small number of devices). iOS, macOS
> and Windows are **not tested**; the Flutter SDK supports Android only. Code that may support a
> platform is not the same as a tested platform. Before distributing an app, read the
> [Google Play policy considerations](policy/google-play.md). See
> [Platform Support & Testing Status](../README.md#platform-support--testing-status) and
> [limitations.md](limitations.md#platform-limitations).

## Learn (tutorial)

| Page | You will |
|---|---|
| [installation.md](installation.md) | Run the server locally with Docker, publish a test patch and see it in the official demo app ([`packages/ota_client/example`](../packages/ota_client/example/README.md)) |
| [community/testing-guide.md](community/testing-guide.md) | Test Flutter OTA System on your machine and devices, and report the results |

## Do a task (how-to guides)

| Page | Task |
|---|---|
| [flutter-integration.md](flutter-integration.md) | Add the Flutter SDK (`flutter_ota_system`) to your Flutter app |
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
| [why-flutter-ota-system.md](why-flutter-ota-system.md) | Why self-host your OTA infrastructure; a sourced comparison with Shorebird |
| [concepts.md](concepts.md) | Releases, patches, compatibility, channels, rollouts, rollback, revocation |
| [architecture.md](architecture.md) | Control plane, data plane and on-device runtime; flows and database |
| [security.md](security.md) | Security model, implemented vs planned controls, threat model |
| [signing-key-management.md](signing-key-management.md) | Signing keys and the trust model: verified limitations, rotation, compromise, future Key Vault |
| [privacy-and-data-handling.md](privacy-and-data-handling.md) | Field-by-field inventory of what the SDK and server store, send and log |
| [platform-compatibility.md](platform-compatibility.md) | Supported and tested platforms, Flutter versions, Flutter internals relied upon |
| [policy/google-play.md](policy/google-play.md) | Google Play policy considerations for code patches (Device and Network Abuse) |
| [policy/apple-app-store.md](policy/apple-app-store.md) | Apple App Store considerations (Guideline 2.5.2); no iOS support |
| [limitations.md](limitations.md) | What is tested, experimental, planned or unsupported |
| [known-issues.md](known-issues.md) | Known bugs, with priority and proposed fixes |
| [roadmap/](roadmap/README.md) | Implemented, experimental, planned and unsupported work |
| [adr/](adr/README.md) | Architecture decision records for the current system |

## Bytecode patch engine (research, not in the SDK)

| Page | Contents |
|---|---|
| [architecture/bytecode-architecture.md](architecture/bytecode-architecture.md) | Short summary: what the bytecode engine is, what was measured, what does not exist yet |
| [architecture/bytecode-compatibility-matrix.md](architecture/bytecode-compatibility-matrix.md) | What a bytecode patch can and cannot change (one test phone) |
| [architecture/adr/](architecture/adr/0001-bytecode-engine-and-developer-experience.md) | Decision record for the bytecode engine (separate ADR series, status: Proposed) |
| [architecture/phase-1-prototype-report.md](architecture/phase-1-prototype-report.md), [phase-2-compatibility-report.md](architecture/phase-2-compatibility-report.md) | Detailed engineering reports of the research prototypes |

## Project

| Page | Contents |
|---|---|
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Development setup, tests, pull requests |
| [SECURITY.md](../SECURITY.md) | Reporting vulnerabilities privately |
| [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) | Community rules |
| [release/v0.1.0-alpha.1.md](release/v0.1.0-alpha.1.md) | Release notes of the first public alpha |
| [release/](release/PREPUBLISH_CHECKLIST.md) | Maintainers only: pre-publish checklists and GitHub settings |

All documentation describes **v0.1.0-alpha.1**. Where a page and the code disagree, the code is
correct; please open an issue.
