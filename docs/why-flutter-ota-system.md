# Why Flutter OTA System?

**Your Flutter OTA infrastructure. Your servers. Your data. Your control.**

Flutter OTA System is an experimental, self-hosted, open-source (Apache-2.0) over-the-air (OTA)
patch platform for Flutter apps. This page explains when that model makes sense and when it does
not. It also compares it fairly with [Shorebird](https://shorebird.dev/), the established Flutter
code push service.

> [!IMPORTANT]
> Flutter OTA System is an **alpha** (v0.1.0-alpha.1). It has been tested internally on **Linux**
> and a **small number of Android devices** only. It has had no independent security audit and no
> load tests, and it is **not production-validated**. Shorebird is far more mature. This page
> compares **architectural approaches**; it does not claim that one technology is better.

Statements about Shorebird come from its official website and documentation, as accessed on
**2026-11-11**, and link to their sources. Products change. Check the linked pages before you
decide, and [open an issue](https://github.com/punitsoni22/flutter_ota_system/issues) if anything
here is out of date.

## 1. Why self-hosted OTA infrastructure matters

An OTA system decides **which code runs inside your users' apps**. Whoever operates it controls:

- **Where data goes.** Every app start or update check sends a request to the update server.
  That request contains the app, release, platform, architecture, channel and current patch.
- **Where your builds are stored.** A code push system stores your store builds and patches.
- **Who can ship code.** The signing key, and the people and systems that can use it, decide
  what your users run.
- **How rollouts behave.** That covers who gets a patch, when, and what happens when it fails.

For many teams, a managed service is the right trade: someone else runs and secures all of this.
Some teams need these pieces **inside their own infrastructure** instead, because of:

- internal policy;
- customer contracts;
- data-residency rules;
- air-gapped or private networks;
- a wish to read, audit and change every part of the pipeline.

Flutter OTA System is built for that case.

## 2. Shorebird's architecture and service model

Shorebird is the most widely known code push solution for Flutter. It was founded in 2023 by
Flutter's creator ([shorebird.dev](https://shorebird.dev/)) and reached 1.0 in April 2024.

- **Managed service.** Shorebird runs the backend for you:
  - release binary (private) storage;
  - patch binary (public) storage and serving through a global CDN;
  - patch-check requests;
  - a web console;
  - a database.

  "The majority of Shorebird's infrastructure is hosted on Google Cloud Platform", using "US
  regions by default"
  ([system architecture](https://docs.shorebird.dev/code-push/system-architecture/)).
- **No self-hosted version.** "Shorebird has no plans to offer on-premises or self-hosted
  versions" ([FAQ](https://docs.shorebird.dev/code-push/faq/)).
- **Open-source components.** Shorebird is not closed source. Several of its components are
  public:
  - the CLI and the Dart client and protocol libraries are dual-licensed Apache-2.0/MIT
    ([shorebirdtech/shorebird](https://github.com/shorebirdtech/shorebird));
  - the Rust updater that runs inside apps ([shorebirdtech/updater](https://github.com/shorebirdtech/updater));
  - its Flutter fork ([github.com/shorebirdtech](https://github.com/shorebirdtech)).

  What is not offered is the **hosted service** in a form you can run yourself.
- **Patch engine.**
  - "Shorebird is a fork of Flutter that adds Code Push" ([shorebird.dev](https://shorebird.dev/)).
  - On Android and desktop, "a Shorebird patch simply provides a new compiled version of your
    Dart code".
  - On iOS, changed code runs in "a novel Dart interpreter"
    ([system architecture](https://docs.shorebird.dev/code-push/system-architecture/)).
- **Platforms:** Android, iOS, macOS, Windows and Linux
  ([FAQ](https://docs.shorebird.dev/code-push/faq/)). Desktop support left beta in February 2025
  ([blog](https://shorebird.dev/blog/desktop-in-production)).
- **Features:**
  - tracks (`stable`, `beta`, `staging` and custom ones;
    [tracks](https://docs.shorebird.dev/code-push/tracks/));
  - a console, patch rollbacks and signed patches, in every plan
    ([pricing](https://shorebird.dev/pricing));
  - user roles on paid plans, and SAML, SCIM and audit logs on Enterprise.
- **Signing:** RSA keys. By default Shorebird manages the key in Google Cloud KMS, or you can
  sign with your own key ([patch signing](https://docs.shorebird.dev/code-push/guides/patch-signing/)).
- **Percentage rollouts:** documented as something you build with tracks plus your own app logic
  and a key-value store
  ([guide](https://docs.shorebird.dev/code-push/guides/percentage-based-rollouts/)).
- **Pricing** (2026-11-11, [shorebird.dev/pricing](https://shorebird.dev/pricing)):

  | Plan | Price | Patch installs a month |
  |---|---|---|
  | Hobby | $0 | 5,000 |
  | Pro | $20/month | 50,000 |
  | Business | $400/month | 1,000,000 |
  | Enterprise | Custom | Custom |

  Paid plans charge $1 per 2,500 extra installs.

## 3. What you control with Flutter OTA System

Everything in this list is in the code on `main`. It runs on your infrastructure or your machine.

| Part | What runs where | Status |
|---|---|---|
| Update server | FastAPI service (`backend/`) in your Docker Compose stack | ✅ Tested (automated tests + CI end-to-end demo) |
| Database | Your PostgreSQL 17 (releases, patches, channels, devices, counters) | ✅ Tested |
| Patch files | Your disk served by nginx, or your S3-compatible bucket; content-addressed, immutable | ✅ Disk tested; 🟢 S3 used internally, tests use a mock |
| Builds and patch compilation | On **your** machine (or CI) with the `flutter_ota` CLI and the custom toolchain. No source code is uploaded | 🟡 Experimental (bytecode architecture) |
| Signing keys | **Bytecode architecture:** an offline root key and a certified signer key on your machine; the server only verifies. **Original alpha:** an ES256 key on your server | 🟡 Experimental / ✅ Tested; no KMS/HSM support |
| Update-check rules | Readable Python in [`backend/app/updates.py`](../backend/app/updates.py) | ✅ Tested |
| Rollout logic | HMAC bucketing in [`backend/app/bucket.py`](../backend/app/bucket.py), server-side promotion checks | ✅ Tested |
| Device traffic | Devices talk only to the URLs you configure (`serverUrl` and your file server or bucket) | ✅ Tested |
| Client | The `flutter_ota_system` package (in this repository) with the Flutter OTA custom engine | 🟡 Experimental: bytecode patches tested on one Android 13 phone |

✅ = implemented and tested · 🟢 = implemented, partially tested · 🟡 = experimental.
Details: [limitations](limitations.md).

## 4. Advantages of self-hosting

- **Data stays with you.** Update checks, device records and counters go to your PostgreSQL.
  They do not go to a third party. A device sends its installation id, platform, arch, release,
  channel and current patch number.
- **Your network, your rules.** Run the server on a private network, behind your VPN or WAF,
  or in your region. Devices only need to reach the URLs you configure.
- **Your keys.** In the bytecode architecture, the private signing keys never leave your machine:
  the server only verifies, and the app trusts only the root keys compiled into it.
- **No per-install pricing.** The software is free (Apache-2.0). You pay for your own servers,
  storage, bandwidth and time instead (see [section 7](#7-cost-and-operational-responsibility)).
- **No dependency on a vendor's roadmap or availability.** You can fork the project and keep it
  running however you like.

## 5. Infrastructure ownership

- **Deployment:**
  - **Tested:** the local stack (`./flutter-ota-system.sh setup`) on Linux.
  - **Not verified yet:** a single-server Docker setup with Caddy for HTTPS
    ([operations.md](operations.md)).
  - **In principle:** the backend is a container plus PostgreSQL plus S3-compatible or disk
    storage, so it can run on a Linux VM at AWS, Azure, another cloud or your own hardware.
    None of these deployments has been verified by the maintainers.
- **Storage:** local disk + nginx, or any S3-compatible service. There is **no Azure Blob
  adapter** yet.
- **Backups:** `./flutter-ota-system.sh backup` / `restore` covers the database, patch files,
  signing key and `.env`, with checksums. Restore refuses a damaged backup.
- **Signing:** you generate and hold the keys (`flutter_ota keys init`; for the original alpha,
  the server key from `scripts/generate_dev_signing_key.sh`). Keep a protected offline backup of
  the root key: whoever has your keys can ship code to your apps.

## 6. Customisation possibilities

Because you run the source, you can change behaviour that a managed service fixes for you. You
then maintain your fork.

- **Update-check rules.** The hot path is about 150 lines of Python
  ([`updates.py`](../backend/app/updates.py)). Compatibility is checked first (release, platform,
  arch, format), the rollout bucket last.
- **Rollout policy.** Rollouts are deterministic HMAC buckets in basis points
  ([`bucket.py`](../backend/app/bucket.py)). Promotion checks for `production` live on the
  server ([`routers/admin.py`](../backend/app/routers/admin.py)).
- **Device targeting.** Today you can target by application, release, platform, architecture,
  channel and percentage ([releases and patches](releases-and-patches.md#staged-rollout)). There is no targeting by
  model, OS version, country or user yet. Because the server is yours, you can add such rules
  yourself.
- **Integrations.** The admin API is plain REST with an OpenAPI page at `/docs`, so CI pipelines,
  internal dashboards and chat-ops tools can call it.
- **Storage and signing back ends** sit behind small interfaces
  ([`storage.py`](../backend/app/storage.py), [`signing.py`](../backend/app/signing.py)).
  Azure Blob and Key Vault adapters are on the
  [roadmap](roadmap/README.md#planned--not-implemented).

Changes to the signed message or the rollout protocol must change both the server and
`ota_client` ([CONTRIBUTING.md](../CONTRIBUTING.md)).

## 7. Cost and operational responsibility

Self-hosting **moves** costs; it does not remove them. You pay for:

- servers or VMs, PostgreSQL, storage and bandwidth (patch downloads);
- TLS certificates, DNS, monitoring, backups and restore tests;
- security work: patching the OS and containers, protecting the admin API key and signing key,
  incident response;
- your team's time to run upgrades, investigate failures and keep up with Flutter releases.

Flutter OTA System does not yet ship dashboards, alerts, automatic rollout pausing, rate
limiting, RBAC or an audit log. If you need them, you build or add them. A managed service
includes such things in its price.

## 8. When to choose Shorebird

Choose Shorebird if:

- you need **iOS** code push (Flutter OTA System has none), or desktop;
- you want a **production-proven** service, maintained by a company with a support channel;
- you do not want to run, secure and monitor OTA servers yourself;
- you need team features today: user roles, SSO, SCIM, audit logs (on its paid plans);
- your data and hosting requirements are satisfied by its hosted model;
- you prefer integration through its CLI and Flutter fork over adding a client package to your
  app.

## 9. When to consider Flutter OTA System

Consider Flutter OTA System if:

- your OTA infrastructure **must run on servers you control**: a private network, your own
  cloud account, your own region, or an air-gapped environment;
- you need to **read, audit and modify** the server, rollout and signing logic;
- you want **built-in** deterministic percentage rollouts and server-enforced promotion checks;
- **Android arm64** and patches to code in **feature packages** cover your needs;
- you are able and willing to operate the stack yourself and to **validate it** (security,
  devices, Flutter versions) before relying on it;
- you want to contribute to an open-source, self-hosted option for the Flutter ecosystem.

Not sure? Run both on a test app. Flutter OTA System's local stack starts with one command
([self-hosting](self-hosting.md)).

## 10. Current technical limitations

| Area | Status |
|---|---|
| Maturity | Experimental alpha; APIs, schema and patch formats may change before 1.0 |
| Platforms tested | Linux (development) and Android 13 / arm64-v8a phones (the bytecode architecture on one phone) |
| iOS | **Not implemented** |
| macOS / Windows | Not supported as development machines; not tested as Docker hosts |
| Code patches | Android arm64, Dart code in feature packages only, Flutter 3.47.9 with the custom engine; the exact store build is required; interpreted code is slower for CPU-heavy work |
| Distribution | Packages not yet on pub.dev; custom toolchain not yet published |
| Security | No independent audit; one shared admin API key; no RBAC, SSO or audit log; open device registration; no rate limiting |
| Signing | Developer-owned keys with rotation and revocation (bytecode); server key for the original alpha; no KMS/HSM |
| Deployment | Local stack tested; single-server `deploy/` setup not verified |
| Scale | No load tests and no capacity claim |
| Monitoring | Per-patch counters and a device summary; no dashboards or alerts |

Details: [limitations](limitations.md) · [security](security.md).

---

Flutter OTA System is not affiliated with or endorsed by Google, the Flutter project or Shorebird.
"Flutter" is a trademark of Google LLC. "Shorebird" is used only to refer to that product.
