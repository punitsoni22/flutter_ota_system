# Flutter OTA System documentation

Flutter OTA System is an experimental, self-hosted OTA update platform for Flutter apps. New here? Start with the [README](../README.md), then the [quick start](quick-start.md).

## Get started

| Page | What it covers |
| --- | --- |
| [Quick start](quick-start.md) | Install, connect your app, release, patch, check status, roll back |
| [Self-hosting](self-hosting.md) | Run the server locally with Docker |
| [Demo app](../packages/ota_client/example/README.md) | A real feature (API + freezed model + UI) patched from v1 to v2 |

## Use it

| Page | What it covers |
| --- | --- |
| [Flutter integration](flutter-integration.md) | The SDK: `FlutterOta.initialize()`, `OtaFeature`, generated files, logs |
| [Feature patching](feature-patching.md) | What can be patched, feature packages, dependency closure, freezed |
| [CLI reference](cli-reference.md) | Every `flutter_ota` command, and the admin `ota` CLI |
| [Toolchain management](toolchain-management.md) | The custom Flutter toolchain: install, verify, upgrade, build it yourself |
| [Releases, patches and rollouts](releases-and-patches.md) | Patch life cycle, channels, staged rollout, rollback, revocation |
| [Troubleshooting](troubleshooting.md) | Common errors and what to do |

## Run the server

| Page | What it covers |
| --- | --- |
| [Operations](operations.md) | Single-server deployment (draft), backups, upgrades, monitoring |
| [Configuration](configuration.md) | Server, CLI and build settings |
| [API reference](api-reference.md) | Device and admin REST API |

## Understand it

| Page | What it covers |
| --- | --- |
| [Architecture](architecture.md) | Developer machine, self-hosted backend and phone: what runs where |
| [Security](security.md) | Developer-owned signing, verification, known security limitations |
| [Compatibility and limitations](limitations.md) | What is supported, what is not, what is not tested yet |
| [Why Flutter OTA System?](why-flutter-ota-system.md) | Why self-host OTA updates |
| [Privacy and data handling](privacy-and-data-handling.md) | What the server stores about devices |
| Store policies | [Google Play](policy/google-play.md) · [Apple App Store](policy/apple-app-store.md) |

## For contributors

| Page | What it covers |
| --- | --- |
| [CONTRIBUTING](../CONTRIBUTING.md) | How to contribute and test |
| [Testing guide](community/testing-guide.md) | What to test and report |
| [Runtime contract](architecture/runtime-contract.md) | CLI ↔ SDK ↔ patch module contract |
| [SDK runtime](architecture/phase-4-sdk-runtime.md) · [Backend protocol](architecture/phase-4-backend-protocol.md) · [Bytecode verifier](architecture/bytecode-verifier.md) | Implementation references |
| [Decision records](adr/README.md) | Architecture decisions |
| [Roadmap](roadmap/README.md) | What is planned |
| [Prototypes](../prototypes/README.md) | The research prototypes behind the bytecode architecture |
| [CHANGELOG](../CHANGELOG.md) · Release notes: [v0.3.0-alpha](release/v0.3.0-alpha.md) · [v0.2.0-alpha](release/v0.2.0-alpha.md) · [v0.1.0-alpha.1](release/v0.1.0-alpha.1.md) | What changed |
