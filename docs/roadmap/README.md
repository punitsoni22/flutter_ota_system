# Flutter OTA System roadmap

What exists today, what is experimental, and what is planned. Planned items are goals, not
promises, and have no dates.

> [!IMPORTANT]
> **The code is the source of truth.** Where this page and the code disagree, the code wins;
> please open an issue.

**Status legend:**

| Mark | Meaning |
|---|---|
| ✅ **Implemented** | In the code, covered by tests or `scripts/verify_demo.sh`, internally tested only |
| 🟡 **Experimental** | Exists, but is limited, lightly tested or a research prototype |
| 🔭 **Planned** | Not built. A future goal, not a promise |
| ❌ **Unsupported** | Not supported and not planned for now |

Nothing in Flutter OTA System is production-validated yet (see the warning in the
[README](../../README.md)).

---

## Current state

### Implemented ✅ (original alpha, `v0.1.0-alpha.1`)

- FastAPI control plane with PostgreSQL: apps, channels, releases, patches, devices, per-patch
  event counters. Alembic migrations.
- Device API: `POST /v1/devices/register`, `GET /v1/updates/check`, `POST /v1/events/batch`.
- Admin API (single shared API key) and one static admin page at `/admin`.
- Content-addressed, immutable patch storage: local disk served by nginx, or S3-compatible
  buckets.
- Server-side ES256 signing of a canonical patch message, verified in Dart (`mock-v1`).
- Deterministic percentage rollout, rollback and revoke.
- `ota` admin CLI, local Docker Compose stack, demo and verification scripts, GitHub Actions CI.

### Experimental 🟡 (unreleased bytecode architecture, on `main`)

- **Custom Flutter engine** (Flutter 3.47.9 / Dart 3.13.7) with the Dart bytecode interpreter and
  an in-VM bytecode verifier. Android arm64 only.
- **`flutter_ota` CLI:** automatic toolchain management, keys, doctor, local store release, feature
  dependency analysis and generated registry, local bytecode compilation, verification and
  signing, status, rollback.
- **SDK runtime:** `FlutterOta.initialize()`, feature slots, separate-process verification,
  activation at the next start, crash recovery.
- **Backend:** developer-signed `dbc-v1` patches (the server verifies, never signs), trust roots,
  certificates, signed revocation lists.
- Tested end to end on one Android 13 arm64 phone ([limitations](../limitations.md)).
- **Android code patches on stock Flutter** (original alpha, `aot-bidiff-android-v1`): loads a
  downloaded native `libapp.so`, a significant Google Play policy risk
  ([policy/google-play.md](../policy/google-play.md)).

### Planned 🔭 (not implemented)

- **Final deep-testing phase** for the bytecode architecture: more devices and Android versions,
  large apps (size, start-up, memory), crash recovery on device, store-release compatibility,
  security fuzzing, a second Flutter version ([limitations](../limitations.md#not-tested-yet)).
- **Publishing:** the packages on pub.dev and an official, signed toolchain download.
- **Whole-app patching** (patching code outside feature packages): research only.
- **Users, roles (RBAC), SSO and an audit log.** Today there is one shared admin API key.
- **Key Vault / KMS / HSM signing.** Today keys are files ([security](../security.md)).
- **Rate limiting** on device endpoints, token refresh, idempotency keys.
- **Targeting** by device attributes (today: channel + percentage only).
- **Caching** of the update check (Redis or in-process); no cache exists today.
- **Cloud deployment templates** (for example Azure Blob Storage, a CDN, container hosting) and
  deployment workflows. Today's self-hosting path is Docker ([operations.md](../operations.md)).
- **Observability:** OpenTelemetry, dashboards, alerts, automatic rollout pausing.
- **Load and chaos testing.** No load test has been run and no capacity is claimed.

### Unsupported ❌

- **iOS code patches.** Apple does not allow apps to download and run native code, and nothing
  has been built or tested on iOS ([policy/apple-app-store.md](../policy/apple-app-store.md)).
- macOS, Windows, Linux and web *apps* (the SDK declares Android only).

### Platform testing (planned)

Today only a **Linux** development environment and the **Android** Flutter app have been tested
internally, on a small number of devices
([compatibility](../limitations.md#compatibility)). These testing tasks are 🔭
**planned, not done**:

- 🔭 **Android device and OS-version compatibility:** test on more devices, manufacturers and
  Android versions, and publish a compatibility matrix.
- 🔭 **CPU architecture (ABI) compatibility:** the bytecode architecture supports `arm64-v8a`
  only; other ABIs need engine builds.
- 🔭 **Flutter version compatibility:** test `flutter_ota_system` and Android code patches across
  Flutter stable releases, and publish which versions work.
- 🔭 **macOS development environment:** the local Docker stack, and host builds of the
  toolchain so the `flutter_ota` CLI can run on macOS.
- 🔭 **Windows development environment:** the same on Windows (Docker Desktop, and WSL 2 if
  needed).

Installation-specific items are listed in
[installation-improvements.md](installation-improvements.md).

---

## Design rules

These rules are followed by the current code and must stay true for planned work.

1. **The runtime is a plugin.** The backend never depends on how a patch runs (`PatchRuntime`,
   [ADR-0001](../adr/0001-runtime-abstraction.md)).
2. **Patch bytes never go through FastAPI** on the device path. The API returns a URL, and the
   file server or bucket serves the bytes.
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

## Version rules (current behaviour)

| Situation | What happens | Status |
|---|---|---|
| Phone on 1.0.0, patches 1–4 exist | Gets **patch 4 directly**, not 1→2→3→4 (each patch is a diff from the *store build*) | ✅ |
| New install of 1.0.0 *after* patch 4 was published | Gets patch 4 on first check | ✅ |
| Phone on 1.1.0 | Never sees 1.0.0's patches. 1.1.0 has its own patch list starting at 1 | ✅ |
| Patch 4 rolled back | Every check response tells phones "patch 4 is bad / roll back to 3" | ✅ |
| Patch crashes on start | Next start loads the last good patch or the store build, and reports a boot failure | ✅ (Android code patches: experimental) |
| Phone offline / server down | App runs its current good code. OTA never blocks startup | ✅ |
| Many phones open the app at the same time | Checks are spread by server-set intervals and client jitter | 🔭 Not load-tested. No cache exists |

---

## Top risks

| Risk | What protects you today | Planned |
|---|---|---|
| Google Play policy on downloaded `.so` code | Per-app distribution type and a recorded policy approval before code patches (`ota app approve-policy`) | Bytecode engine (better policy position, still uncertain); legal review per app |
| Apple policy / technical block on iOS | No iOS code patches at all | — |
| Flutter upgrades break Android code patches | The CLI refuses a patch built with a different Flutter version | Upgrade runbook |
| Signing key stolen | Key is a local file or env var, kept off the repo. **This is weak** ([security.md](../security.md)) | Key Vault/KMS/HSM, rotation runbook, two-person publish |
| Bricking phones | Boot-confirm protocol, last-known-good fallback, `OtaBoot` re-checks the patched file's SHA-256 before loading it | Chaos tests |
| Native/asset change shipped as a patch | The CLI compares every non-`libapp.so` file with the release and refuses | — |
| All devices checking at once | The server sets the check interval and the client adds jitter; progressive rollout | Cached deployment head, load tests |
| No dashboards | Roll out slowly (1% first) and read boot-failure counts on `/admin` before each step up | Dashboards, alerts, automatic pause |

## Glossary

| Term | Meaning |
|---|---|
| **OTA** | Over-the-air: updating an app without going through the App Store or Play Store |
| **Release** | A build you shipped through the store (e.g. `1.0.0+100`). Patches are always *for* one release |
| **Patch** | A change delivered OTA to one release. Numbered 1, 2, 3… per release |
| **Artifact** | An actual file (store build or patch) for one platform and CPU architecture |
| **ABI / arch** | CPU architecture of an Android phone: `arm64-v8a` (almost all), `armeabi-v7a`, `x86_64` |
| **`libapp.so`** | The file your Dart code is compiled into on Android. The experimental Android runtime swaps it |
| **Dart bytecode / dynamic module** | Dart code compiled to bytecode and run by the Dart VM interpreter; needs a custom engine build (research only) |
| **Binary diff** | A small file that turns the old `libapp.so` into the new one (bsdiff) |
| **Channel** | A named audience: `dev`, `staging`, `production` |
| **Rollout** | Making a patch available to X% of a channel |
| **Bucket** | A fixed number 0–9999 per device. A device is in a 10% rollout if its bucket is below 1000 |
| **Rollback** | "Go back to the previous patch" |
| **Revoke** | "This patch must never run again, anywhere" |
| **Control plane / data plane** | The API that decides vs the file server/bucket that serves the files |
| **ADR** | Architecture Decision Record: a short document explaining one decision and why |
