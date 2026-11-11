# Launch announcements (drafts)

Ready-to-post drafts for introducing Flutter OTA System v0.1.0-alpha.1. They are written for the
maintainers; adapt them before posting.

**Before posting anywhere:**

- Read the community's self-promotion rules (subreddit sidebar, server `#rules` channel, HN
  guidelines). Some only allow project posts on certain days or in certain channels.
- Post from a personal account, as the maintainer, and stay to answer questions for the first
  few hours. Technical replies matter more than the post.
- Do not add claims that are not in these drafts. Every statement below is checked against the
  code and docs at tag `v0.1.0-alpha.1`. In particular, never claim production readiness, iOS
  support, scale numbers, or that the project is "better than" Shorebird.
- Enable GitHub Discussions first if you will link to it (**Settings → General → Features →
  Discussions**).

Links used below:

- Repository: <https://github.com/punitsoni22/flutter_ota_system>
- Release: <https://github.com/punitsoni22/flutter_ota_system/releases/tag/v0.1.0-alpha.1>
- Testing guide: <https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/community/testing-guide.md>
- Comparison: <https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/why-flutter-ota-system.md>

---

## Reddit (r/FlutterDev)

**Title:** I built a self-hosted OTA patch server for Flutter (Android Dart code patches on stock
Flutter, alpha). Looking for testers.

**Body:**

I've been working on **Flutter OTA System**, an open-source (Apache-2.0), self-hosted
over-the-air patch system for Flutter apps. The first alpha is out, and I'm looking for people
willing to break it.

**The problem I wanted to solve:** shipping a Dart fix without a full store review cycle, while
keeping the update server, the database, the patch files and the signing key on infrastructure I
control. Shorebird is the established option and is more mature. It is a managed service, though,
and I wanted something I could run and modify myself.

**What it does today:**

- **Server:** FastAPI + PostgreSQL + nginx (or any S3-compatible bucket), started with one
  command (`./flutter-ota-system.sh setup`) in Docker Compose.
- **Release binding:** every patch is tied to one exact store build (`1.0.0+1`), platform, CPU
  architecture and format.
- **Signing:** the server signs patch metadata with ES256. The app verifies the signature with
  keys compiled into it **before** downloading, then checks size and SHA-256.
- **Rollouts:** channels (`dev`/`staging`/`production`), deterministic percentage rollouts,
  rollback and revoke.
- **Boot protection:** if a patched app doesn't confirm a successful start, the next start goes
  back to the last good code, and the server stops offering that patch to that device.
- **Android Dart code patches (experimental):** `ota release android` registers the store build;
  `ota patch android` rebuilds, refuses anything that changed outside Dart code (native libs,
  `.dex`, manifest, resources, assets, Flutter version), and uploads a binary diff of `libapp.so`
  per ABI. No engine fork: a small Java class points Flutter's loader at the verified library at
  process start.

**What it is NOT (yet):**

- not production-ready;
- no iOS code patches;
- tested only on Linux and a small number of Android 13 / arm64 devices;
- no security audit and no load tests;
- one shared admin API key (no roles).

**What would help most:** run `./flutter-ota-system.sh setup && ./flutter-ota-system.sh demo` on
your machine, try the example app on your phone, and file a test report, even if everything
worked. Different Android versions, ABIs, Flutter versions, and macOS/Windows hosts are the big
unknowns. The testing guide lists 13 things to try: <testing guide link>

Repo: <repository link>

Happy to answer questions about the patch format, signing or the Android loader trick.

---

## Hacker News (Show HN)

**Title:** Show HN: Flutter OTA System – self-hosted code push for Flutter apps (alpha)

**URL:** the repository link.

**First comment (post it yourself right after submitting):**

Flutter OTA System is a self-hosted over-the-air patch server and client for Flutter apps,
Apache-2.0. It's an early alpha. I'm posting it because the design choices might be interesting,
and I need people to test it on hardware I don't have.

Architecture, briefly:

- **Control plane:** FastAPI + PostgreSQL. It answers `GET /v1/updates/check` and stores releases,
  patches, channels and per-patch counters (boot ok/failed, downloads).
- **Data plane:** patch files are content-addressed by SHA-256 and immutable, served by nginx from
  disk or from any S3-compatible bucket. The API never streams patch bytes.
- **Signing:** the server signs a canonical, length-prefixed message (app, release, patch number,
  platform, arch, format, base/payload/result hashes, size) with ES256. The Dart client verifies
  it against public keys compiled into the app *before* downloading, then checks size and hash.
  So a compromised file server or CDN can't ship code, but a compromised signing key can.
- **Rollouts:** bucket = HMAC-SHA256(secret, app ‖ installation id ‖ patch id) mod 10,000. That
  makes rollouts sticky: going from 1% to 10% keeps the first 1%. Rolled-back and revoked patch
  numbers ride along on every update-check response. The server never offers an older patch
  unless the current one is bad (anti-replay).
- **Promotion checks:** a patch can't grow on `production` unless it ran on another channel
  first and has no reported boot failures. Overriding needs a logged reason.
- **Android code patches on stock Flutter:** at release time the CLI extracts `libapp.so` (the
  AOT-compiled Dart code) per ABI and fingerprints everything else in the APK/AAB. At patch time
  it rebuilds, refuses any change outside Dart code or any Flutter version change, and uploads a
  binary diff. It also checks locally that the diff rebuilds the new file exactly. On the device,
  `ota_client` rebuilds the library, checks base and result hashes, and stages it. A small Java
  class then calls `FlutterLoader.ensureInitializationComplete` with `--aot-shared-library-name`
  pointing at it, before any engine exists. If the next start doesn't confirm success, it falls
  back to the last good library.

**Honest limits:** Android only (iOS doesn't allow loading new AOT code, and I haven't
implemented an interpreter). It depends on Flutter's loader behaviour, which could change. It
has been tested internally on Linux and a small number of Android 13 arm64 devices. There is no
security audit, no load test and no RBAC. Shorebird solves the same problem with a modified
engine and a managed service, and is far more mature. This project is for people who want to own
and modify the whole pipeline.

Docs on the security model, known issues and limitations are in the repo. I'd especially like
feedback on the signing scheme and the rollout/rollback protocol.

---

## DEV Community article

**Title:** Building a self-hosted OTA patch system for Flutter

**Tags:** `flutter`, `dart`, `opensource`, `devops`

**Cover image:** the project icon (`docs/assets/flutter-ota-system-icon.png`) or an architecture
diagram screenshot.

**Article:**

Most Flutter teams ship fixes the slow way: build, upload, wait for review, wait for users to
update. Code push services shorten that loop. I wanted one I could **run myself**, on a server I
control, with the signing key never leaving my infrastructure. So I built **Flutter OTA System**,
an open-source (Apache-2.0) self-hosted OTA patch platform. The first alpha is out. This post
explains how it works and what I learned.

> ⚠️ It's an experimental alpha: tested internally on Linux and a small number of Android
> devices, no security audit, not for production yet.

### The pieces

```
Developer (ota CLI)  ──►  FastAPI + PostgreSQL  ──►  patch files (nginx or S3-compatible)
                                 ▲                              │
Flutter app (ota_client) ────────┴──── check ─── download ◄─────┘
```

- **Control plane.** A FastAPI service with PostgreSQL. It knows apps, store releases, patches,
  channels and devices, and answers one hot-path question: *is there a patch for this device?*
- **Data plane.** Patch files are stored under their SHA-256 and never change. nginx serves them
  from disk, or you point the server at an S3-compatible bucket. The API only hands out URLs.
- **Client.** The `ota_client` Dart package. It registers the device, checks for updates,
  verifies, downloads, stages and activates patches, and reports counters.
- **CLI.** `ota`, a Python CLI that builds releases and patches and manages rollouts.

Everything runs in Docker Compose. `./flutter-ota-system.sh setup` creates a `.env` with random
local secrets and a dev signing key, builds and starts the stack, and waits for health checks.

### Rule 1: a patch belongs to exactly one store build

A patch is only valid for the exact release it was built against: version and build number,
platform, CPU architecture and patch format. The server checks compatibility first and the
rollout bucket last. A patch for `1.0.0+1` will never reach `1.0.0+2`. That rule removes a whole
class of "patch applied to the wrong binary" failures.

### Rule 2: verify before you download

The server signs a canonical message describing the patch with ES256 (ECDSA P-256): app, release,
patch number, platform, arch, format, hashes and size. The message is length-prefixed, so fields
can't be shifted into each other. The app has the public keys compiled in. It verifies the
signature **before** downloading anything, so a forged response costs no bandwidth. After the
download it checks the exact size and the SHA-256.

The consequence is a clear trust boundary. The file server and CDN don't need to be trusted;
the **signing key** does. Whoever holds it can ship code to your users, so it lives only on your
server.

### Rule 3: rollouts must be sticky

The rollout bucket is `HMAC-SHA256(secret, app, installation id, patch id) mod 10000`, and a
device is in the rollout if its bucket is below the rollout's basis points. The same device
always gets the same bucket for the same patch. Raising 1% → 10% keeps the first 1% and adds
more devices. Nobody flips back and forth.

`production` is guarded on the server. A patch can't be raised there unless it ran on another
channel first and has no reported boot failures. Overriding needs `--force` plus a reason, which
is logged.

### Rule 4: a bad patch must never brick the app

The client writes the patch to try next and the last one that booted fine. If a patched start
doesn't confirm success (the app calls `markBootSuccessfulAfterFirstFrame`), the next start
falls back to the last good code. The failed patch's id is sent with later checks, so the server
offers the next best patch instead. From the server you can also **roll back** (devices return
to the previous patch) or **revoke** (the patch never runs again). The lists of rolled-back and
revoked patches ride along on every update-check response.

### The interesting part: Dart code patches on stock Flutter (Android)

In a release build, your Dart code is compiled ahead of time into `libapp.so`. Flutter's Android
embedding accepts a flag, `--aot-shared-library-name`, that tells it which library to load. A
small Java class (`OtaBoot`) runs at process start, before any Flutter engine exists. It reads
which patch to boot and points `FlutterLoader` at the verified library in the app's own files
directory. No engine fork is needed.

The CLI does the heavy lifting:

1. `ota release android` builds the store APK/AAB and extracts `libapp.so` per ABI. It
   fingerprints everything else (native libraries, `.dex`, manifest, resources, Flutter assets,
   Flutter version) and registers the release.
2. `ota patch android` rebuilds with your changes and compares the fingerprints. It **refuses**
   the patch if anything outside Dart code changed, because that can't be patched this way. It
   then computes a binary diff of `libapp.so` per ABI, checks that the diff rebuilds the new file
   exactly, and uploads it. The server signs each artifact as it arrives.
3. On the device, `ota_client` rebuilds `libapp.so` from the diff and checks the base and result
   hashes. It stages the library, and the next start runs it.

Limits: Android only. iOS doesn't allow loading new compiled code, which is why Shorebird uses
its own engine with an interpreter there. Plugins with native code and Flutter upgrades need a new
store release. The approach also depends on Flutter's loader behaviour, so every Flutter upgrade
needs re-testing.

### Testing so far

- backend tests (24) and `ota_client` tests (20), run in CI;
- an end-to-end demo with 32 checks, also run in CI;
- shellcheck, a gitleaks secret scan and a Docker build;
- manual tests on a small number of Android 13 / arm64-v8a devices: config patches and code
  patches, crash fallback, rollback, revoke, the store-policy gate, and release re-registration.

What's **not** tested: iOS, macOS and Windows hosts, other Android versions and ABIs, Flutter
versions beyond the one used, and anything at scale.

### Why self-hosted?

Shorebird is the mature choice for Flutter code push. It supports iOS and has a managed console,
and it publishes open-source components. If you want a managed service, use it. Flutter OTA
System is for a different situation: you want the update server, database, patch storage and
signing key on your own infrastructure, and you want to read and change every line of the
pipeline. Self-hosting isn't free. You run, secure, back up and monitor the server yourself. A
longer, sourced comparison is in the repo: <comparison link>

### Try it, break it, tell me

```bash
git clone https://github.com/punitsoni22/flutter_ota_system.git
cd flutter_ota_system
./flutter-ota-system.sh setup
./flutter-ota-system.sh demo
```

The testing guide lists 13 things to try, from a fresh install to rollback on a phone:
<testing guide link>. Test reports are welcome even when everything works; that is how we learn
which environments are safe. Repo: <repository link>

---

## LinkedIn

I've released the first alpha of **Flutter OTA System**: an open-source, self-hosted
over-the-air update platform for Flutter apps.

The idea is simple: **your Flutter OTA infrastructure, on your servers, under your control.**
You run the update server (FastAPI + PostgreSQL), keep patch files on your own disk or
S3-compatible storage, and keep the signing key on your own infrastructure.

What's in v0.1.0-alpha.1:

- **Patches and releases:** signed patches (ES256 + SHA-256), each bound to one exact store
  release;
- **Rollouts:** channels, deterministic staged rollouts, rollback and revoke;
- **Boot protection:** automatic fallback when a patched app fails to start;
- **Android code patches (experimental):** Dart code patches on stock Flutter;
- **Setup:** a one-command Docker setup, a CLI and a small admin page.

It is an experimental alpha. It has been tested internally on Linux and a small number of Android
devices, and has not been security-audited or production-validated. Shorebird remains the mature,
managed option. This project is for teams who need to own and customise the pipeline themselves.

I'm looking for:

- **Flutter developers** to test the Android workflow on their devices and Flutter versions;
- **DevOps and platform engineers** to review the deployment, security model and operations;
- **Contributors** for documentation, tests and fixes.

Apache-2.0 licensed. Repo and testing guide: <repository link>

#Flutter #Dart #OpenSource #DevOps #MobileDevelopment #SelfHosted

---

## Flutter Discord (short intro)

Post only in the channel the server allows for project showcases.

> Hi all 👋 I've open-sourced **Flutter OTA System**, a self-hosted OTA patch server + client for
> Flutter (Apache-2.0, early alpha). You run the server yourself (FastAPI + Postgres, one-command
> Docker setup); patches are ES256-signed and verified on the device; you get channels, staged
> rollouts, rollback, and automatic fallback if a patch fails to start. There are also
> experimental Android Dart code patches on stock Flutter (no engine fork).
>
> It's only been tested on Linux + a few Android 13 phones, so I'd love test reports from other
> devices, Android versions or Flutter versions. Not production-ready, no iOS code patches.
> Repo + 13-step testing guide: <repository link>

---

## GitHub Discussions (Announcements category): tester recruitment

**Title:** 🧪 Help test v0.1.0-alpha.1: we need your devices and setups

**Body:**

v0.1.0-alpha.1 is the first public alpha of Flutter OTA System. So far it has been tested on
**one Linux development environment** and **a small number of Android 13 / arm64-v8a devices**.
Everything beyond that is unknown, and that is where you can help.

**Most wanted:**

- Android versions other than 13, and other manufacturers;
- `armeabi-v7a` and `x86_64` (emulator) builds;
- Flutter versions other than 3.44 stable (the package requires ≥ 3.27);
- the local Docker stack on **macOS** or **Windows** (Docker Desktop, WSL 2, Colima);
- other Linux distributions;
- your own app with `ota_client`, not just the example app.

**How:**

1. Follow the [testing guide](../blob/main/docs/community/testing-guide.md). It has 13 areas, from
   a fresh install to rollback. Do as many as you can.
2. File a **Test report** issue with your environment and the results. "Everything worked on X"
   is a valuable report.
3. One specific bug? Use the **Bug report** form.

**Please never post** `.env` contents, admin keys, signing keys or tokens. Security problems go
through *Security → Report a vulnerability*, not public threads.

Questions about setup or ideas for features: reply here or open a new discussion. Thank you! 🙏
