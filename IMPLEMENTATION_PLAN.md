# Flutter OTA — Implementation Plan

This is the master plan. It explains **what** to build and in **which order**. Each phase has its own beginner-friendly guide in [docs/plan/](docs/plan/) that explains **how**: the commands, the code, and how to check it worked.

Sources: *Open-Source Flutter OTA Platform for One Million DAU: Production Blueprint*, and *Shorebird Deep Research and Blueprint* (2026-09-27).

---

## Scope (updated 2026-10-30)

**We are building:** Shorebird-style code push for Flutter. You ship a store release once, then fix **Dart code** over the air. Every patch belongs to exactly one release version, and the system is sized for **1M active installs**.

| In scope | Out of scope (for now) |
|---|---|
| Release ↔ patch version matching (1.0.0 patches never reach 1.1.0) | Flutter Web admin console. The CLI and CI do everything |
| Patch files on a CDN, hash + signature checks | Telemetry dashboards, alerts, automatic rollout pausing |
| Boot protection: a crashing patch falls back automatically | Patching native code, plugins, assets or permissions (needs a store release, always) |
| Channels, % rollout, rollback, revoke | iOS code push (research track, after Android works) |
| **Android engine fork** that runs patched Dart code | |
| Azure deployment + GitHub Actions CI/CD | |
| Load tested for 1M installs | |

The decision and its reasons are in [ADR-0011](docs/adr/0011-scope-and-runtime-path.md).

**Distribution:** apps ship through the public stores **and** internally. Enterprise apps may receive Android code patches as soon as the runtime works. Public Play Store apps only after a written policy review (see [Track R, step R.0](docs/plan/runtime-android-engine.md#r0-store-policy-gate-do-this-before-writing-engine-code)).

---

## How to use this plan

1. Do the phases **in order**. Each one builds on the previous one. The exception is the runtime track, which runs in parallel (see the timeline below).
2. Open the phase guide, and do one numbered step at a time.
3. Every step has three parts:
   - **Why:** what the step is for.
   - **Do:** the commands or code.
   - **Check:** how to prove it works before moving on.
4. Tick the box in the progress tracker below when a step's check passes.
5. Commit after every step (`git add -A && git commit -m "phase 2.3: ..."`). Small commits make mistakes easy to undo.

If you are stuck on a step for more than an hour, re-read its **Why**. Most problems come from building the right thing in the wrong place.

---

## Current state: MVP built (2026-10-30)

A working local MVP covers the core of Phases 2–7 plus slim 8/9: backend, `ota` CLI, Flutter `ota_client`, an example app, and Docker Compose. Patches are signed `mock-v1` JSON files until Track R delivers the engine runtime. **How to run and test it:** [docs/mvp-testing.md](docs/mvp-testing.md). The phase guides below remain the path to production: migrations, Key Vault, Azure, CI, load tests.

## Progress tracker

| Phase | Guide | Status |
|---|---|---|
| Setup | [00-setup-your-machine.md](docs/plan/00-setup-your-machine.md) | ⬜ Docker still needs installing |
| 0 — Protocol decisions | [phase-00-protocol-decisions.md](docs/plan/phase-00-protocol-decisions.md) | 🟡 ADR-0001/0002/0011 drafted for review |
| 1 — Foundations | [phase-01-foundations.md](docs/plan/phase-01-foundations.md) | ⬜ |
| 2 — Release domain | [phase-02-release-domain.md](docs/plan/phase-02-release-domain.md) | ⬜ |
| 3 — Device control plane | [phase-03-device-control-plane.md](docs/plan/phase-03-device-control-plane.md) | ⬜ |
| 4 — Artifact storage | [phase-04-artifact-storage.md](docs/plan/phase-04-artifact-storage.md) | ⬜ |
| 5 — Flutter client | [phase-05-flutter-client.md](docs/plan/phase-05-flutter-client.md) | ⬜ |
| 6 — Signing | [phase-06-signing.md](docs/plan/phase-06-signing.md) | ⬜ |
| 7 — Rollout / rollback / revoke | [phase-07-rollout.md](docs/plan/phase-07-rollout.md) | ⬜ |
| 8 — CLI/CI auth *(slimmed)* | [phase-08-admin-rbac.md](docs/plan/phase-08-admin-rbac.md) | ⬜ Skip 8.6 (web console) |
| 9 — Boot events *(slimmed)* | [phase-09-telemetry.md](docs/plan/phase-09-telemetry.md) | ⬜ Only 9.1–9.3 + 9.5 |
| 10 — Azure + CI/CD | [phase-10-azure-cicd.md](docs/plan/phase-10-azure-cicd.md) | ⬜ |
| 11 — Scale + hardening (1M) | [phase-11-hardening.md](docs/plan/phase-11-hardening.md) | ⬜ |
| **R — Android engine fork** | [runtime-android-engine.md](docs/plan/runtime-android-engine.md) | ⬜ **Core**, runs in parallel |
| R-iOS — iOS research | [runtime-ios-research.md](docs/plan/runtime-ios-research.md) | ⬜ After Track R |

---

## The big picture

```
 Developer / CI                       CONTROL PLANE (small JSON)
 ota release / ota patch ──────────►  FastAPI ──► PostgreSQL (releases, patches, rollouts)
   │  (builds with YOUR engine)          │     ──► Key Vault (signing)
   │                                     │
   └── patch diff files ──► Blob Storage ◄── Front Door CDN ◄── patch download
                                                        ▲
 Phone (app built with your engine fork)                │
   ota_client (Dart): check → download → verify hash + signature → rebuild libapp.so → stage
   engine hook (Java): on next start load patched libapp.so, or the base one if anything is wrong
```

- **Control plane:** decides *which release* gets *which patch* for *which device*. Small, fast, and it never serves files.
- **Data plane:** the CDN serves patch files. This is where 1M installs × patch size goes.
- **Client:** downloads, verifies, stages, and protects the boot.
- **Runtime (Track R):** the engine fork that actually runs the new Dart code.

---

## Timeline: two tracks in parallel

```
Backend/client track:  0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 ───────────► 8s → 9s → 10 → 11
                                            │      │    │
Runtime track:         R.0 → R.1 → R.2 → R.3 → R.4 ─┴─ R.5 → R.6 ─┴─ R.7 → R.8 → R.9 ─► R-iOS
                       (research: can start right after Setup)
```

- R.0–R.4 are research and need no backend. Start them early. Building the engine takes days, so let it run while you do Phases 1–3.
- R.5–R.6 need the Phase 5 client (state file + boot protocol).
- R.7 (the `ota patch` CLI) needs Phase 4 (upload) and Phase 6 (signing).
- Until R.6 is done, the platform is tested with `mock-v1` inert files. After that, the same pipeline carries real code.

---

## The rules

These come from the blueprint. Break any of them and the system fails at scale.

1. **The runtime is a plugin.** The backend never depends on how a patch runs (`PatchRuntime`, ADR-0001).
2. **Patch bytes never go through FastAPI.** The API returns a URL, and the CDN serves the bytes.
3. **Files are immutable.** No `latest.patch`. Every file is named by its SHA-256 hash and never overwritten.
4. **Never trust the network or the disk.** The client checks hash and signature every time, and the engine re-checks the rebuilt `libapp.so` hash before loading it. The store-installed app must *always* still boot.
5. **A patch belongs to exactly one release, ABI and engine version.** Never offer a patch across versions.
6. **Rollout is deterministic.** Each device gets a fixed bucket 0–9999 from an HMAC. Never use `random()`.
7. **Native or asset changes need a store release.** The CLI refuses to build a patch from them.
8. **Everything runs locally first.** Docker Compose before Azure.

---

## Phases at a glance

| # | Phase | You'll have at the end | Effort |
|---|---|---|---|
| 0 | Protocol decisions | Written decisions (ADRs) for formats, signing, rollback, scope | 0.5 pw |
| 1 | Foundations | API skeleton, Docker stack, tests, CI | 2–3 pw |
| 2 | Release domain | Tables and rules: app → release → patch, per platform/ABI | 2–3 pw |
| 3 | Device control plane | Devices register and ask "any update?" (**Milestone A**) | 2–3 pw |
| 4 | Artifact storage | Patch files in Blob storage, downloaded via CDN redirect | 1–2 pw |
| 5 | Flutter client | A phone downloads, verifies, stages, boot protection (**Milestone B**) | 2–3 pw |
| 6 | Signing | Only patches signed by your key are accepted (**Milestone C**) | 2–4 pw |
| 7 | Rollout | 1% → 10% → 100%, rollback, revoke (**Milestone D**) | 3–4 pw |
| 8s | CLI/CI auth | Entra ID / API keys + roles for the CLI and CI. No web UI | 1–2 pw |
| 9s | Boot events | Devices report patch boot success/failure. Counts per patch | 1 pw |
| 10 | Azure + CI/CD | Everything deployed to Azure from GitHub (**Milestone F**) | 3–5 pw |
| 11 | Hardening | Load tested for 1M installs (10k RPS burst), chaos tests, DR (**Milestone G**) | 4–6 pw |
| R | Android engine fork | **Real Dart code patches on Android** (**Milestone R**) | 12–20 pw |
| R-iOS | iOS research | A chosen iOS approach, backed by spikes | 2–4 pw (research only) |

*pw = person-weeks of focused work. As a beginner, expect roughly 1.5× these numbers. That is normal.*

**Total to "Android code push in production on Azure for 1M installs":** about 36–56 pw (×1.5 as a beginner).

---

## Version and scale rules (the "Shorebird behaviour")

| Situation | What happens |
|---|---|
| Phone on 1.0.0, patches 1–4 exist | Gets **patch 4 directly**, not 1→2→3→4 (each patch is a diff from the *base*, not from the previous patch) |
| New install of 1.0.0 *after* patch 4 was published | Gets patch 4 on first check |
| Phone on 1.1.0 | Never sees 1.0.0's patches. 1.1.0 has its own patch list starting at 1 |
| Patch 4 rolled back | Every check response tells phones "patch 4 is revoked / roll back to 3" (ADR-0005) |
| Patch crashes on start | Next start loads the last good patch or the base. Reported as a boot failure |
| Phone offline / server down | App runs its current good code. OTA never blocks startup |
| 1M phones open the app at 9:00 | Checks spread by jitter, answered from cache (Phase 7.8/11). Bytes come from the CDN |

---

## Glossary

| Term | Meaning |
|---|---|
| **OTA** | Over-the-air: updating an app without going through the App Store or Play Store |
| **Release** | A build you shipped through the store (e.g. `1.0.0+100`). Patches are always *for* one release |
| **Patch** | A change delivered OTA to one release. Numbered 1, 2, 3… per release |
| **Artifact** | An actual file (base build or patch) for one platform and CPU architecture |
| **ABI** | CPU architecture of an Android phone: `arm64-v8a` (almost all), `armeabi-v7a`, `x86_64` |
| **`libapp.so`** | The file your Dart code is compiled into on Android. The engine fork swaps it |
| **Engine fork** | Your copy of Flutter with a small change that can load a patched `libapp.so` |
| **Binary diff** | A small file that turns the old `libapp.so` into the new one |
| **Channel** | A named audience: `dev`, `qa`, `production` |
| **Rollout** | Making a patch available to X% of a channel |
| **Bucket** | A fixed number 0–9999 per device. A device is in a 10% rollout if its bucket is below 1000 |
| **Rollback** | "Go back to the previous patch" |
| **Revoke** | "This patch must never run again, anywhere" |
| **Control plane / data plane** | The API that decides vs the CDN that serves the files |
| **ADR** | Architecture Decision Record: a short document explaining one decision and why |
| **JWT** | A signed token the device sends to prove who it is |
| **CDN** | Content Delivery Network: servers worldwide that cache files near users |
| **OIDC** | How GitHub Actions logs into Azure without storing a password |

---

## Top risks

| Risk | What protects you |
|---|---|
| Google Play policy on downloaded `.so` code | Policy gate: AOT patches only for enterprise apps until a legal review approves public apps (R.0) |
| Apple policy / technical block on iOS | iOS is a research track. No iOS patches without an interpreter approach and a legal review |
| Flutter upgrades break the engine hook | Tiny hook, upgrade runbook (R.9), pin one Flutter version per release, keep old engines |
| Signing key stolen | Key lives in Azure Key Vault and never leaves it. Two-person approval to publish. Rotation runbook |
| Bricking phones | Boot-confirm protocol, last-known-good fallback, engine re-checks hash, chaos tests |
| Native/asset change shipped as a patch | The CLI compares every non-`libapp.so` file with the release and refuses |
| All devices checking at once | Jitter, back-off, cached deployment head, progressive rollout |
| No dashboards (scope cut) | Roll out slowly (1% first) and read boot-failure counts before each step up |
