# Flutter OTA System roadmap

This folder holds Flutter OTA System's **roadmap**: what exists today, what is partly built, and what is
planned. It started as the step-by-step plan used to build Flutter OTA System. The phase guides still teach
*how* each piece is meant to work, so they are kept. Read them as design notes, not as a
description of the current code.

> [!IMPORTANT]
> **The code is the source of truth.** Where a phase guide and the code disagree (file names,
> package layout, endpoints), the code wins. Each phase guide starts with a status box that says
> what was actually built.

**Status legend** (used in every roadmap file):

| Mark | Meaning |
|---|---|
| ✅ **Implemented** | In the code, covered by tests or `scripts/verify_demo.sh`, internally tested only |
| 🟡 **Partial** | Some of it exists, or a simpler version was built. The status box says what is missing |
| 🔭 **Planned** | Not built. A future goal, not a promise |

Nothing in Flutter OTA System is production-validated yet (see the warning in the [README](../../README.md)).

---

## Current state (v0.1.0-alpha.1)

### Implemented ✅

- FastAPI control plane with PostgreSQL: apps, channels, releases, patches, devices, per-patch
  event counters. Alembic migrations.
- Device API: `POST /v1/devices/register`, `GET /v1/updates/check`, `POST /v1/events/batch`.
- Admin API (single shared API key) and one static admin page at `/admin`.
- Content-addressed, immutable patch storage: local disk served by nginx, or S3-compatible
  buckets.
- ES256 signing of a canonical patch message, verified in Dart against embedded public keys.
- Deterministic percentage rollout, rollback and revoke (the bad-patch lists ride on every check).
- `ota_client` Flutter package: check, download, size + SHA-256 + signature checks, staging, boot
  protection, telemetry.
- `ota` CLI, local Docker Compose stack, demo and verification scripts, GitHub Actions CI.

### Experimental 🟡

- Android Dart code patches on **stock Flutter** (`aot-bidiff-android-v1`): `ota release android`
  / `ota patch android`, `OtaBoot.java`. Tested internally on a small number of devices. See
  [releases-and-patches.md](../releases-and-patches.md).

### Planned 🔭 (not implemented)

- **Azure**: Blob Storage adapter, Key Vault signer, Front Door CDN, Container Apps, Bicep,
  OIDC deployment ([Phase 10](phase-10-azure-cicd.md)).
- **Redis** or any shared cache for the update check ([Phase 7.8](phase-07-rollout.md#78-deployment-head-cache),
  [Phase 11.2](phase-11-hardening.md#112-decide-on-redis)).
- **Users, roles (RBAC), SSO and an audit log** ([Phase 8](phase-08-admin-rbac.md)).
- **Scale target of 1 million active installs.** This is a design goal only. No load test has
  been run and no capacity is claimed ([Phase 11](phase-11-hardening.md)).
- Rate limiting, token refresh, idempotency keys, OpenTelemetry, dashboards, alerts, automatic
  rollout pausing.
- iOS code push: research only ([runtime-ios-research.md](runtime-ios-research.md)).

### Platform testing (planned)

Today only a **Linux** development environment and the **Android** Flutter app have been tested
internally, on a small number of devices
([README](../../README.md#platform-support--testing-status)). These testing tasks are 🔭
**planned, not done**:

- 🔭 **Android device and OS-version compatibility:** test on more devices, manufacturers and
  Android versions, and publish a compatibility matrix.
- 🔭 **CPU architecture (ABI) compatibility:** test code patches and `mock-v1` on `arm64-v8a`,
  `armeabi-v7a` and `x86_64` builds.
- 🔭 **Flutter version compatibility:** test `ota_client` and Android code patches across Flutter
  stable releases, and publish which versions work.
- 🔭 **iOS build and runtime testing** on macOS with Xcode: build the example app and check
  whether the `mock-v1` runtime works. iOS code patches stay out of scope
  ([runtime-ios-research.md](runtime-ios-research.md)).
- 🔭 **macOS development environment:** run the local Docker stack (Docker Desktop), the CLI and
  the Android build/patch flow on macOS.
- 🔭 **Windows development environment:** the same on Windows (Docker Desktop, and WSL 2 if
  needed).

Installation-specific items are also listed in
[installation-improvements.md](installation-improvements.md).

---

## Progress by phase

| Phase | Guide | Status |
|---|---|---|
| Setup | [00-setup-your-machine.md](00-setup-your-machine.md) | ✅ Guide (tools to install) |
| 0 — Protocol decisions | [phase-00-protocol-decisions.md](phase-00-protocol-decisions.md) | 🟡 ADR-0001, 0002, 0011 written. 0003–0010 decided and implemented in code, not yet written up ([ADR index](../adr/README.md)) |
| 1 — Foundations | [phase-01-foundations.md](phase-01-foundations.md) | ✅ Mostly. No request IDs, Makefile or Dart workspace |
| 2 — Release domain | [phase-02-release-domain.md](phase-02-release-domain.md) | ✅ Simplified schema (9 tables). Tests use SQLite, not testcontainers |
| 3 — Device control plane | [phase-03-device-control-plane.md](phase-03-device-control-plane.md) | 🟡 Register + check done. No token refresh, separate heartbeat or rate limiting |
| 4 — Artifact storage | [phase-04-artifact-storage.md](phase-04-artifact-storage.md) | 🟡 Local disk + S3-compatible. **No Azure Blob.** Direct upload instead of prepare/commit |
| 5 — Flutter client | [phase-05-flutter-client.md](phase-05-flutter-client.md) | ✅ In one package (`ota_client`) instead of four |
| 6 — Signing | [phase-06-signing.md](phase-06-signing.md) | 🟡 Local PEM signer + Dart verify + key set. **No Key Vault**, no rotation runbook |
| 7 — Rollout / rollback / revoke | [phase-07-rollout.md](phase-07-rollout.md) | ✅ Except targeting and the deployment-head cache (**no Redis**) |
| 8 — Admin auth and roles | [phase-08-admin-rbac.md](phase-08-admin-rbac.md) | 🔭 One shared admin API key only. **No Entra ID, roles or audit log** |
| 9 — Telemetry | [phase-09-telemetry.md](phase-09-telemetry.md) | 🟡 Events + counters in Postgres, CLI promote guard. No Event Hubs, OpenTelemetry, dashboards or alerts |
| 10 — Azure + CI/CD | [phase-10-azure-cicd.md](phase-10-azure-cicd.md) | 🔭 **Not started.** CI exists; no Azure deployment |
| 11 — Scale + hardening (1M goal) | [phase-11-hardening.md](phase-11-hardening.md) | 🔭 Mostly planned. Secret scan + licence gate in CI, backup script. **No load tests** |
| R — Android code patches | [runtime-android-engine.md](runtime-android-engine.md) | 🟡 Experimental, built on stock Flutter **without** an engine fork |
| R-iOS — iOS research | [runtime-ios-research.md](runtime-ios-research.md) | 🔭 Research notes only |

---

## How to use the phase guides

Each guide is split into numbered steps, and every step has three parts:

- **Why:** what the step is for.
- **Do:** the commands or code (as originally planned).
- **Check:** how to prove it works.

To work on a planned item: read its status box, read the step, then compare with the current code
before you change anything. Open an issue first for anything large (see
[CONTRIBUTING.md](../../CONTRIBUTING.md)).

---

## Target architecture (planned)

Today Flutter OTA System runs as **FastAPI + PostgreSQL + local disk/nginx or an S3-compatible bucket**
([architecture.md](../architecture.md)). The diagram below is the **planned** Azure shape. The
parts marked 🔭 do not exist yet.

```
 Developer / CI                       CONTROL PLANE (small JSON)
 ota release / ota patch ──────────►  FastAPI ──► PostgreSQL (releases, patches, rollouts)
   │                                     │     ──► 🔭 Key Vault (signing)
   │                                     │
   └── patch diff files ──► 🔭 Blob Storage ◄── 🔭 Front Door CDN ◄── patch download
                                                        ▲
 Phone (your app + ota_client)                          │
   ota_client (Dart): check → download → verify hash + signature → rebuild libapp.so → stage
   OtaBoot (Java): on next start load the patched libapp.so, or the store one if anything is wrong
```

- **Control plane:** decides *which release* gets *which patch* for *which device*. Small, fast,
  and it never serves files.
- **Data plane:** the CDN or bucket serves patch files. This is where installs × patch size goes.
- **Client:** downloads, verifies, stages, and protects the boot.
- **Runtime:** what actually runs the new Dart code (Track R).

---

## Design rules

These rules are followed by the current code and must stay true for planned work.

1. **The runtime is a plugin.** The backend never depends on how a patch runs (`PatchRuntime`,
   [ADR-0001](../adr/0001-runtime-abstraction.md)).
2. **Patch bytes never go through FastAPI** on the device path. The API returns a URL, and the
   CDN/bucket serves the bytes.
3. **Files are immutable.** No `latest.patch`. Every file is named by its SHA-256 hash and never
   overwritten.
4. **Never trust the network or the disk.** The client checks size, hash and signature every
   time. The store-installed app must *always* still boot.
5. **A patch belongs to exactly one release, platform and CPU architecture.** Never offer a patch
   across versions.
6. **Rollout is deterministic.** Each device gets a fixed bucket 0–9999 from an HMAC. Never use
   `random()`.
7. **Native or asset changes need a store release.** The CLI refuses to build a patch from them.
8. **Everything runs locally first.** Docker Compose before any cloud.

---

## Phases at a glance (with original effort estimates)

| # | Phase | Goal at the end | Effort | Status |
|---|---|---|---|---|
| 0 | Protocol decisions | Written decisions (ADRs) for formats, signing, rollback, scope | 0.5 pw | 🟡 |
| 1 | Foundations | API skeleton, Docker stack, tests, CI | 2–3 pw | ✅ |
| 2 | Release domain | Tables and rules: app → release → patch, per platform/arch | 2–3 pw | ✅ |
| 3 | Device control plane | Devices register and ask "any update?" | 2–3 pw | 🟡 |
| 4 | Artifact storage | Patch files in object storage, downloaded from a CDN | 1–2 pw | 🟡 |
| 5 | Flutter client | A phone downloads, verifies, stages, with boot protection | 2–3 pw | ✅ |
| 6 | Signing | Only patches signed by your key are accepted | 2–4 pw | 🟡 |
| 7 | Rollout | 1% → 10% → 100%, rollback, revoke | 3–4 pw | ✅ |
| 8 | Admin auth and roles | Entra ID / per-person keys + roles for the CLI and CI | 1–2 pw | 🔭 |
| 9 | Telemetry | Devices report boot success/failure; counts per patch | 1 pw | 🟡 |
| 10 | Azure + CI/CD | Everything deployed to Azure from GitHub | 3–5 pw | 🔭 |
| 11 | Hardening | Load tests toward the 1M-installs goal, chaos tests, DR | 4–6 pw | 🔭 |
| R | Android code patches | Real Dart code patches on Android | 12–20 pw (engine-fork estimate) | 🟡 |
| R-iOS | iOS research | A chosen iOS approach, backed by spikes | 2–4 pw (research) | 🔭 |

*pw = person-weeks of focused work. These are the original planning estimates, kept for
reference.*

---

## Version and scale rules (target behaviour)

| Situation | What happens | Status |
|---|---|---|
| Phone on 1.0.0, patches 1–4 exist | Gets **patch 4 directly**, not 1→2→3→4 (each patch is a diff from the *store build*) | ✅ |
| New install of 1.0.0 *after* patch 4 was published | Gets patch 4 on first check | ✅ |
| Phone on 1.1.0 | Never sees 1.0.0's patches. 1.1.0 has its own patch list starting at 1 | ✅ |
| Patch 4 rolled back | Every check response tells phones "patch 4 is bad / roll back to 3" | ✅ |
| Patch crashes on start | Next start loads the last good patch or the store build, and reports a boot failure | ✅ (Android code patches: experimental) |
| Phone offline / server down | App runs its current good code. OTA never blocks startup | ✅ |
| 1M phones open the app at 9:00 | Checks spread by jitter, answered from a cache, bytes from a CDN | 🔭 Design goal, not tested. No cache exists |

---

## Glossary

| Term | Meaning |
|---|---|
| **OTA** | Over-the-air: updating an app without going through the App Store or Play Store |
| **Release** | A build you shipped through the store (e.g. `1.0.0+100`). Patches are always *for* one release |
| **Patch** | A change delivered OTA to one release. Numbered 1, 2, 3… per release |
| **Artifact** | An actual file (store build or patch) for one platform and CPU architecture |
| **ABI / arch** | CPU architecture of an Android phone: `arm64-v8a` (almost all), `armeabi-v7a`, `x86_64` |
| **`libapp.so`** | The file your Dart code is compiled into on Android. Flutter OTA System's Android runtime swaps it |
| **Engine fork** | A modified copy of the Flutter engine. Flutter OTA System does **not** use one today |
| **Binary diff** | A small file that turns the old `libapp.so` into the new one (bsdiff) |
| **Channel** | A named audience: `dev`, `staging`, `production` |
| **Rollout** | Making a patch available to X% of a channel |
| **Bucket** | A fixed number 0–9999 per device. A device is in a 10% rollout if its bucket is below 1000 |
| **Rollback** | "Go back to the previous patch" |
| **Revoke** | "This patch must never run again, anywhere" |
| **Control plane / data plane** | The API that decides vs the CDN/bucket that serves the files |
| **ADR** | Architecture Decision Record: a short document explaining one decision and why |
| **JWT** | A signed token the device sends to prove who it is |
| **CDN** | Content Delivery Network: servers worldwide that cache files near users |
| **OIDC** | How GitHub Actions can log into a cloud without a stored password (planned, Phase 10) |

---

## Top risks

| Risk | What protects you today | Planned |
|---|---|---|
| Google Play policy on downloaded `.so` code | Per-app distribution type and a recorded policy approval before code patches (`ota app approve-policy`) | Legal review per app |
| Apple policy / technical block on iOS | No iOS code patches at all | iOS research track |
| Flutter upgrades break Android code patches | The CLI refuses a patch built with a different Flutter version | Upgrade runbook |
| Signing key stolen | Key is a local file or env var, kept off the repo. **This is weak** ([security.md](../security.md)) | Key Vault/KMS/HSM, rotation runbook, two-person publish |
| Bricking phones | Boot-confirm protocol, last-known-good fallback, `OtaBoot` re-checks the patched file's SHA-256 before loading it | Chaos tests |
| Native/asset change shipped as a patch | The CLI compares every non-`libapp.so` file with the release and refuses | — |
| All devices checking at once | The server sets the check interval and the client adds jitter; progressive rollout | Cached deployment head (Redis or in-process), load tests |
| No dashboards | Roll out slowly (1% first) and read boot-failure counts on `/admin` before each step up | Dashboards, alerts, automatic pause |
