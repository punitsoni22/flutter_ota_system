# Alternative patch engine research

Research and architecture planning for evolving Flutter OTA System's Android code-patch engine.
**Research only: no implementation, no code changes.** Researched on **2026-11-12**.

> [!IMPORTANT]
> This documentation is provided for technical guidance and is not legal advice. Platform
> policies can change. Developers are responsible for independently reviewing the policies
> applicable to their applications and distribution channels.

**Labels used throughout**

| Label | Meaning |
|---|---|
| **[Verified]** | Checked by us against the primary source (official page or source file) during this research |
| **[Source]** | Observed in a project's source code (file and commit given); read, not executed |
| **[Assumption]** | Our inference or estimate; not verified |
| **[Policy interpretation]** | Our reading of a policy text; uncertain by nature; not legal advice |

Nothing was built or executed from third-party repositories. Source snapshots inspected:
`flutter_patcher` main `5fb8ff0` (2026-11-10; tag v1.1.0 = `14ff562`), `flutter_patcher_artifacts`
main `0480e8a` (2026-11-04), `shorebirdtech/updater` `4573043` (2026-11-11),
`shorebirdtech/shorebird` `4d6a621` (2026-11-11), `shorebirdtech/flutter` `e2c965f` (2026-10-31),
`dart-lang/sdk` main `32c9349` and tag 3.12.2, `flutter/flutter` master `c08f4b8`.

---

## 1. Executive summary

1. **Interpreted Dart patching is impossible on the stock Flutter release engine.** Dart's
   bytecode interpreter exists in the Dart SDK but is compiled out by default
   (`dart_dynamic_modules = false`, also at Dart 3.12.2); on such a runtime loading a module throws
   "Loading of dynamic modules is not supported." **[Verified]** Every interpreter approach needs a
   **custom engine build** (`libflutter.so` + `gen_snapshot`) shipped inside a **new store release**.
2. **Shorebird does not interpret on Android.** Its Android patches are full AOT machine code
   (bidiff + zstd against `libapp.so`), conceptually the same as ours; its interpreter is iOS-only and
   lives in a **private** Dart SDK fork. Shorebird cannot be self-hosted. **[Verified]**
3. **flutter_patcher 1.x** builds a custom engine with Dart's official dynamic-modules interpreter
   switched on (plus three small source patches), compiles changed app packages to bytecode with
   `dart2bytecode`, and loads them with `dart:_internal.loadDynamicModule`. It patches whole packages
   (not single functions), cannot patch Flutter, plugins or FFI code, and supports **only Flutter
   3.47.0–3.47.9**. MIT licensed. **[Source]**
4. **Policy:** native AOT patches (ours, Shorebird Android, flutter_patcher "so") produce executable
   native code outside Google Play. Bytecode run by an interpreter is **closer** to Google Play's
   VM/interpreter exception, but **not automatically compliant**. **[Policy interpretation]**
5. **Our platform already supports this change.** Backend, database, rollouts, signing and the
   client's `PatchRuntime` abstraction are format-agnostic; the `artifact_format` column has no
   database constraint. A new engine replaces only patch generation and patch execution.
   **[Verified]**
6. **Recommendation:** strategy **B, independently implemented**: build our own bytecode runtime on
   Dart's official dynamic-modules interpreter (custom engine builds from BSD-licensed upstream
   sources), learning from flutter_patcher (MIT, with attribution) rather than depending on it, and
   keep the current AOT engine as an experimental option. Rough effort: **45–75 person-weeks** to a
   production-readiness assessment (section 11). **[Assumption]**

---

## 2. Current project status (pre-flight)

- Step 3 documentation is merged (`2ffea84`); CI on that commit passed. **[Verified]**
- There is **no `patch_engine/` directory**. The patch engine consists of:

| Part | File | Role |
|---|---|---|
| Patch generation | [`cli/android.py`](../../cli/android.py), [`cli/otadiff.py`](../../cli/otadiff.py) | Build the app, extract `lib/<abi>/libapp.so`, refuse non-Dart changes, bsdiff (`OTADIF01`) per ABI |
| Signing | [`backend/app/routers/admin.py`](../../backend/app/routers/admin.py), [`signing.py`](../../backend/app/signing.py) | ES256 over the canonical message on upload |
| Download, verification, rebuild | [`ota_client.dart`](../../packages/ota_client/lib/src/ota_client.dart), [`aot_runtime.dart`](../../packages/ota_client/lib/src/aot_runtime.dart) | ES256 before download; size and SHA-256; rebuild `libapp.so`; base and result hashes |
| Loading, crash fallback | [`OtaBoot.java`](../../packages/ota_client/android/src/main/java/io/github/punitsoni22/flutter_ota_system/OtaBoot.java) | Content provider before `Application.onCreate`; `--aot-shared-library-name`; boot attempt markers |

Details: [platform-compatibility.md](../platform-compatibility.md),
[signing-key-management.md](../signing-key-management.md).

---

## 3. The enabling technology: Dart dynamic modules

| Fact | Evidence |
|---|---|
| The Dart VM contains a bytecode interpreter and bytecode loader, compiled only when the GN flag `dart_dynamic_modules` is true | `runtime/runtime_args.gni` line 76 `dart_dynamic_modules = false`; same default at tag 3.12.2 (line 79) **[Verified]**; `runtime/vm/interpreter.h` wrapped in `#if defined(DART_DYNAMIC_MODULES)` **[Source]** |
| Without the flag, loading throws | `runtime/lib/object.cc`: "Loading of dynamic modules is not supported." **[Source]** |
| Not shipped in Dart or Flutter SDKs | `pkg/dynamic_modules/README.md`: "We don't ship this as part of the Dart or Flutter SDKs … needs to be built from sources" **[Verified]** |
| Not a code-push feature | Same README: "Is Dart Dynamic Modules a 'code-push' implementation? No." Modules add code through a declared *dynamic interface*; they cannot replace existing declarations **[Verified]** |
| API is internal and experimental | `package:dynamic_modules` (unpublished) wraps private `dart:_internal` `loadDynamicModule`; "experimental, can be changed or removed without a notice" **[Source]** |
| Stock Flutter engine excludes it | Flutter engine `tools/gn` `--dart-dynamic-modules` default `False`; experimental `-ddm` release artifacts are built **only on master** (`.ci.yaml`: "Don't run this on release branches"); not available for the stable 3.50 engine **[Source]** |
| Flutter's position on code push | flutter/flutter#14330 open (P3); #162206 (override `libapp.so`) closed "not planned": "we don't plan to support code push … You of course are free to fork Flutter" **[Source]** |
| Licence | Dart SDK and Flutter: BSD-3-Clause (forks/custom builds allowed with notices) **[Source]** |

**Consequence:** "interpreter-based OTA" in practice means *a custom engine build that turns on an
experimental, unsupported Dart feature*, plus a technique to make additive-only modules behave like
patches (flutter_patcher renames and re-runs whole packages; see section 4).

---

## 4. flutter_patcher

Repository: <https://github.com/xuelinger2333/flutter_patcher> ·
pub.dev: <https://pub.dev/packages/flutter_patcher> · Licence: **MIT** (package and artifacts repo,
"Copyright (c) 2026 xuelinger") **[Verified]**

### 4.1 Architecture (1.1.0)

```
DEV MACHINE  (dart run flutter_patcher build|patch|publish)
 managed SDK: stock Flutter tag 3.47.x  + patched gen_snapshot
              + local Maven mirror with patched libflutter.so (engine built --dart-dynamic-modules)
 build: inject generated bootstrap main + package "dynamic_modules" (dart:_internal.loadDynamicModule)
        frontend --dynamic-interface=…  →  host APK/IPA  +  BASELINE (app.dill, interface, source hashes,
        engine/flutter versions, fingerprint)
 patch: source-hash diff vs baseline → copy changed own packages renamed package:patch.<id>.<pkg>
        → dart2bytecode (patched) linked against baseline app.dill → module.bc (+assets)
        → ZIP → FPTC v1 file: 146-byte header [magic|ver|fingerprint|seq|len|sha256|Ed25519 sig] + ZIP
DEVICE
 Kotlin/Swift: verify FPTC natively (fingerprint, sha256, signature, seq > high-water, blacklist)
 cold start: generated main → native re-verify → Dart loadDynamicModule(module.bc)
             → VM bytecode interpreter runs the PATCHED main; Flutter/plugins/pinned packages stay AOT
 Android "so" strategy (optional): FlutterLoader replaced by reflection; --aot-shared-library-name
```

### 4.2 Answers to the research questions

| # | Question | Finding |
|---|---|---|
| 1 | Building the original app | Managed stock Flutter clone; `gen_snapshot` and `libflutter.so` (Android) / `Flutter.xcframework` slice (iOS) replaced by **prebuilt patched binaries** from its artifacts repo's GitHub releases; no `--local-engine` (`environment.dart:165-476`, `pipeline.dart:683-733`) **[Source]** |
| 2 | Patch artifacts | Source-file SHA-256 diff vs baseline; tier `lean` (own packages) or `whole` (all non-pinned packages); FPTC v1 file = header + ZIP (`patch_manifest.json`, `module.bc` or `libapp.so`, assets/fonts) (`seal.dart:70-87`) **[Source]** |
| 3 | Dart → bytecode | Dart SDK `pkg/dart2bytecode` with two small patches (`--tfa/--aot-only`, nullable FFI native name), compiled into a tools `.dill` per Flutter version (`tools/versions.json`) **[Source]** |
| 4 | Dart dynamic modules | **Yes**: `import 'dart:_internal' as internal; … internal.loadDynamicModule(bytes: bytes)` (`runtime_package.dart:29`) **[Verified]**; `--dynamic-interface` at build **[Source]** |
| 5 | Interpreter | The Dart VM's own bytecode interpreter, engine built with `--dart-dynamic-modules` (`build_android.sh:34`) **[Verified]**; source patches: one Dart VM fix (factory allocation finalization in `bytecode_reader.cc`), two Flutter patches (in-memory asset channel; background entry points / callbacks routed through a Dart hook) **[Source]** |
| 6 | Imports / namespaces | Changed packages copied and renamed `package:patch.<id>.<pkg>`, imports rewritten; unprefixed libraries rejected **[Source]** |
| 7 | Unchanged vs patched code | **Whole-package replacement**, not per-function: the module carries full renamed copies and runs its own `main`; host AOT copies simply stop being entered **[Source]**. Static/global state is not shared between host and patched copies **[Assumption]** |
| 8 | Flutter framework | Not patchable; pinned to the host. Changing the Flutter version is not possible **[Source]** |
| 9 | Plugins / FFI | Plugins, FFI users and their dependants are pinned; FFI calls forbidden in modules: "in an AOT runtime the VM cannot make an FFI call from interpreted code" (`patch_checks.dart:22`) **[Verified]** |
| 10 | Android vs iOS | Android: Kotlin manager + small C++ JNI bridge, API 28+, main process; bytecode default, "so" optional. iOS: Swift + CryptoKit, bytecode only, Apple Silicon Mac needed to build **[Source]** |
| 11 | Signing | Ed25519, **optional** (`trust.enabled`), one key, no rotation; verified **natively** (Kotlin / CryptoKit) and re-verified at each cold start **[Source]** |
| 12 | Rollback / crash | `maxCrashCount` default 1; `ApplicationExitInfo` crash/ANR detection (API 30+); success marked at first frame; Dart errors watched for 5 s; blacklist; withdrawal files; `rollback()` **[Source]** |
| 13 | Release compatibility | Fingerprint = hash of app, engine, interface, Flutter version and host policy; exact match required; sequence must increase **[Source]** |

### 4.3 Version history: `.so` replacement → bytecode

| Version | Date | Architecture |
|---|---|---|
| 0.1.0–0.1.4 | 2026-05 → | Android only; **whole `libapp.so` replacement on the stock engine** via reflection on `FlutterLoader` (very close to our current engine); 0.1.4 supported Flutter 3.44 **[Source]** |
| **1.0.0** | 2026-11-05 | **Bytecode patches** become the default on Android and the only strategy on iOS: "a patch carries only the changed code, which an interpreter in the engine runs while unchanged code stays machine code"; `--strategy so` keeps the old swap; requires Flutter 3.47.0+ (CHANGELOG.md:296-342) **[Verified]** |
| 1.1.0 | 2026-11-10 | Single-file FPTC format, optional signing, `applyPatchBytes`/`applyPatchFile`/`inspectPatch`, breaking API removal in a minor release **[Source]** |

Stated reasons for the change: iOS forbids downloaded machine code, and smaller patches **[Source,
project docs]**. The change also moved it from the stock engine to a custom engine.

### 4.4 Versions and maintenance

Only Flutter **3.47.0–3.47.9** (`supported_versions.txt`; the CLI refuses others; `pubspec.yaml`
requires Flutter ≥3.47.0, Dart ≥3.13.0) **[Verified]**. Each Flutter version needs its own patched
engine, `gen_snapshot` and tools dill. Single maintainer, very fast release cadence (1.0 → 1.1 in five
days, with breaking changes). **[Source]**

### 4.5 Licence and reuse

| What | Licence | Reuse |
|---|---|---|
| Package and artifacts-repo scripts, patches, tools (author's code) | MIT | Allowed; keep the MIT copyright and permission notice |
| Prebuilt engine / `gen_snapshot` / xcframework binaries | Derived from Flutter/Dart (BSD-3-Clause) and their third parties (e.g. Skia, BoringSSL, ICU) | **No licence or notice files found in the release assets** **[Source]**; reuse would require reproducing the BSD notices. We should **build our own** binaries from upstream sources instead **[Assumption]** |
| Ideas, formats, architecture | Not copyrightable as such | Reimplement independently; credit the project in our docs |

---

## 5. Shorebird

Docs: <https://docs.shorebird.dev/code-push/system-architecture/> (the `/architecture/` URL is not
the real page) · GitHub: <https://github.com/shorebirdtech>

### 5.1 Android vs iOS (they differ fundamentally)

```
ANDROID (no interpreter)
 shorebird patch → build with Shorebird's engine → new libapp.so (full AOT ELF)
   → bidiff(release libapp.so, new) | zstd -21 → CDN
 device: Rust updater in libflutter.so → check api.shorebird.dev → verify → bipatch vs base libapp.so
   → SHA-256 → next start: engine loads patch .vmcode via Dart_LoadELF instead of libapp.so
   → all patched code runs AOT on the CPU

iOS (interpreter, private)
 new code → gen_snapshot (ELF) → aot_tools link vs release snapshot → .vmcode (+ link %)
 device: base App.framework stays loaded; linked (unchanged) functions run AOT;
         changed functions run in Shorebird's Dart interpreter (private Dart SDK fork)
```

| Topic | Finding |
|---|---|
| Android patches | "a Shorebird patch simply provides a new compiled version of your Dart code to run inside the Dart virtual machine" — full AOT, **not interpreted** **[Verified]** |
| Diff format | bidiff + zstd level 21 (`updater/patch/src/lib.rs`) **[Verified]**; applied with bipatch against the base `libapp.so` read from the APK **[Source]** |
| iOS | "comply with those restrictions through use of a novel Dart interpreter"; per-function linker keeps typically ≥98 % of code AOT **[Verified, docs]** |
| Modified engine | Public fork (BSD-3-Clause), now inside `shorebirdtech/flutter`; updater hooks in `shell/common/shorebird/`, `runtime/shorebird/` **[Source]** |
| Modified Dart SDK | "Shorebird's Dart SDK fork is private currently" **[Verified]**; `DEPS` points to `git@github.com:shorebirdtech/dart-sdk.git` (404 publicly) **[Verified]** |
| Toolchain | `aot-tools` (linker), iOS `gen_snapshot` / `analyze_snapshot`: prebuilt binaries only **[Source]** |
| Release compatibility | Patch tied to app, release version, platform, arch; cannot change Flutter version; same `--dart-define`s **[Source, docs]** |
| Crash fallback | Boot breadcrumb in `pointers.json`; failed boot → patch marked bad, fall back **[Source]** |
| Telemetry | Four patch events with a random per-install `client_id`; no crash reports **[Source, docs]** |
| Signing | "Patch Signing": RSASSA-PKCS1-v1_5 SHA-256 over the patch hash; managed (Cloud KMS) or self-managed key **[Source]** |
| Flutter versions | Stable only; new versions "within 5 business days" **[Source, docs]** |
| Self-hosting | FAQ: "Can you self-host Shorebird? No." **[Verified]**; `base_url` only for a proxy forwarding to Shorebird's API **[Source, docs]** |
| Store stance (their claim) | Play: "Shorebird patches run in the Dart virtual machine"; App Store: changed code "in an interpreter" **[Verified quote; not endorsed]** |

### 5.2 Open vs proprietary

| Component | Status | Licence |
|---|---|---|
| CLI (`shorebird`) | Public | Apache-2.0 OR MIT |
| Updater (Rust), patch tool, `shorebird_code_push` | Public | Apache-2.0 OR MIT / MIT |
| Flutter + engine fork | Public | BSD-3-Clause |
| **Dart SDK fork** (interpreter, linker, "maximally similar" compiler) | **Private** | — |
| `aot-tools`, iOS `gen_snapshot` | Binaries only | — |
| API, console, CDN, KMS signing, database | Proprietary service | — |

**What we can learn:** the on-device flow (check/event protocol, diff format, hash/signature checks,
boot state machine, ELF loading). **What we cannot reproduce from public code:** the iOS interpreter,
linker and compiler changes, the `.vmcode` link header, and the build infrastructure. Even the
Android engine probably cannot be built from public sources alone, because `DEPS` points at the
private Dart SDK. **[Assumption]**

---

## 6. Google Play policy assessment

> [!NOTE]
> Technical policy assessment only, not legal advice. Google has not reviewed or approved any of
> these approaches for Flutter OTA System. Policy checked 2026-11-12:
> [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/16559646).

Relevant text **[Verified]**: an app "may not download executable code (such as dex, JAR, .so
files) from a source other than Google Play"; the restriction "does not apply to code that runs in
a virtual machine or an interpreter where either provides indirect access to Android APIs"; and
"Apps or third-party code, like SDKs, with interpreted languages … loaded at run time … must not allow
potential violations of Google Play policies." The first sentence also forbids an app to "modify,
replace, or update itself using any method other than Google Play's update mechanism."

| Approach | Assessment **[Policy interpretation]** |
|---|---|
| **Ours (A):** rebuilt `libapp.so`, native ARM code | Produces and runs native `.so` code from outside Google Play: **significant concern** |
| **Shorebird Android:** full AOT patch loaded as ELF | Technically the same category as ours (native AOT code). Shorebird says patches "run in the Dart virtual machine"; that is their interpretation, which we do not adopt |
| **flutter_patcher "so" strategy** | Same as ours: significant concern |
| **Bytecode interpreted by the Dart VM (B)** | Closer to the exception's wording: the code is interpreted, and module code cannot make FFI calls, so Android APIs are reached only through Flutter/plugins in the host (indirect access). **Uncertain**: the "modify, replace, or update itself" sentence, the interpreted-code clause ("must not allow potential violations") and other policies still apply; a modified Flutter engine is shipped in the store binary |

Remaining limitations even with an interpreter: the update still changes app behaviour outside
Play; the content of each patch must itself comply (e.g. no deceptive changes after review); the
app developer remains responsible for SDK behaviour
([SDK Requirements](https://support.google.com/googleplay/android-developer/answer/13323374)); Apple
Guideline 2.5.2 applies separately for any future iOS work ([apple-app-store.md](../policy/apple-app-store.md)).
**An interpreter does not make an OTA system automatically compliant.**

---

## 7. Architecture comparison

| | **A. Ours: native AOT `.so` replacement** | **B. Bytecode via Dart dynamic modules (flutter_patcher 1.x style)** | **C. Shorebird-style modified runtime** |
|---|---|---|---|
| Flutter changes | None (stock engine; relies on `--aot-shared-library-name`) | Custom engine build with `--dart-dynamic-modules` + small patches (asset channel, entry/callback hook) | Engine fork with updater integration |
| Dart changes | None | Interpreter is upstream; ≥1 small VM fix; patched `dart2bytecode` | Deep private fork (interpreter, linker, compiler) for iOS |
| Build toolchain | `flutter build` + bsdiff | Managed SDK, custom `gen_snapshot`/`libflutter.so`, dynamic interface, bootstrap main, `dart2bytecode` | Full forked SDK, `aot-tools` linker |
| Runtime | Native loader swap at process start | Bytecode loaded by Dart before `runApp` | Engine-integrated updater |
| Patch format | bsdiff of `libapp.so` | Bytecode module (+ assets) | bidiff + zstd of AOT snapshot |
| Patch size | Diff of the whole compiled app; unpredictable **[Assumption]** | Only changed packages' bytecode; typically smaller **[Assumption, project claim]** | Diff of AOT snapshot |
| Runtime performance | Full AOT speed | Patched packages interpreted: slower **[Assumption]**; unchanged code AOT | Android AOT; iOS mostly AOT (≥98 % linked) |
| Android | Yes (experimental) | Yes (API 28+ in flutter_patcher) | Yes |
| iOS | No (impossible) | Technically possible (flutter_patcher does it) — policy review required | Yes (private toolchain) |
| Google Play | Significant concern | Closer to the exception; uncertain | Native AOT on Android: same category as A |
| Security model | ES256, Dart verification, unsigned `boot.json` | Must add our ES256 + native re-verification | RSA patch signing |
| Maintenance | Low code, but fragile Flutter-internal flag | High: engine build per Flutter version, experimental Dart feature | Very high: full fork, private components |
| Flutter upgrades | Re-test the flag; new store release | Rebuild engine/tools per version; re-validate patches | Port fork per version (Shorebird: ~5 business days with a team) |
| Licensing | Our code | Upstream BSD-3 + our code; flutter_patcher MIT if reused | Cannot reuse private parts |
| Self-hosting | Yes | Yes (we host our own engine artifacts) | Shorebird: no; our own clone: impractical |

**Easiest realistic architecture for us:** **B**, implemented by us on upstream Dart dynamic modules,
because the interpreter is open source and upstream, flutter_patcher proves it works end to end, and
our platform layers do not change. C is out of reach for an independent project (private Dart work
for iOS; deep fork to maintain). A is the easiest *today* but has the strongest policy concern and no
path to iOS.

---

## 8. Integration into our platform

Only **patch generation** and **patch execution** change. Everything else is kept.

```
 KEPT AS IS                                   CHANGES
 ─────────────────────────────────────────    ──────────────────────────────────────────────
 FastAPI backend, PostgreSQL, admin UI         CLI: `ota release android --runtime bytecode`,
 apps, releases, channels, rollouts,                `ota patch android` → bytecode module
 device registration, targeting                Build: custom engine artifacts, bootstrap main,
 ES256 signing service + key handling                 dynamic interface, baseline
 artifact storage / CDN, CI                    SDK: new BytecodePatchRuntime (PatchRuntime)
 device API (register / check / events)        Android: native re-verification; no .so swap
```

| Area | Change needed | Existing data preserved? |
|---|---|---|
| 1. Flutter build pipeline | Pin a Flutter version; build our own engine (`libflutter.so`, `gen_snapshot`) with `--dart-dynamic-modules` from upstream sources; inject a generated bootstrap `main` and dynamic interface; save a **baseline** (`app.dill`, interface, source hashes, engine revision) at release time | — |
| 2. Patch CLI | New `ota patch android` path: source diff vs baseline, `dart2bytecode` compile, package module + assets, upload | Existing AOT path stays |
| 3. Flutter SDK | New `BytecodePatchRuntime implements PatchRuntime`: `load()` reads the verified module and starts it; the app's `main` goes through the generated bootstrap | `MockPatchRuntime`, `AotPatchRuntime` unchanged |
| 4. Android native | No `libapp.so` swap; add **native signature re-verification** before load; keep crash breadcrumb | `OtaBoot` kept for format A |
| 5. Artifact format | New `artifact_format`, e.g. `dbc-android-v1`, and a new `runtime_abi` per engine build (e.g. `ota-dbc-android-<engine>`) | The column is `String(32)` with no DB constraint: **no migration** for the format **[Verified]**. Storing the baseline may need a release-artifact "kind" (small migration) **[Assumption]** |
| 6. Backend APIs | Add the format to `ArtifactFormat`/`ARTIFACT_FORMATS`/CLI choices; include it in the `public_store` policy gate; endpoints unchanged | All endpoints and contracts |
| 7. Release compatibility | `runtime_abi`, `engine_revision`, `flutter_version` already stored per release **[Verified]**; base hash = baseline fingerprint | Releases keep their ids |
| 8. Signing | Keep the ES256 canonical message (base = baseline fingerprint, payload = module archive hash, result = module hash); add `patch_id` (protocol v2) and native verification | Same keys, same `publicKeys` |
| 9. Rollback | Server rollback/revoke and client bad lists unchanged; boot confirmation reused; add Dart-error watch during start | Patch history unchanged |
| 10. Telemetry | Same events; add e.g. `patch_load_failed` | Counters unchanged |

**Existing installs:** the interpreter is native code inside `libflutter.so`, so **a new store
release is mandatory**; it cannot be delivered by OTA. Existing releases keep their `aot` patches.
New store builds register as new releases (new `release_version`, new `runtime_abi`); devices
re-register automatically when they update from the store, and history, channels and rollouts carry
over. **[Verified design; Assumption for the details]**

---

## 9. Flutter version compatibility

| Question | Answer |
|---|---|
| Do we need Flutter 3.47 / Dart 3.13? | **To reuse flutter_patcher's artifacts: yes** (3.47.0–3.47.9 only) **[Verified]**. For our own build: not strictly — the interpreter flag exists since Dart 3.6 and at 3.12.2 **[Verified]**, but its behaviour on 3.44 (and whether our patches need different engine fixes) is **untested** **[Assumption]** |
| Adapt to Flutter 3.44.9? | Possible in principle with our own engine build from 3.44.9 sources; flutter_patcher 1.x does not support it **[Source]** |
| Custom Flutter SDK fork? | A **custom build** with a small patch set, not a deep fork; maintained per Flutter version **[Assumption]** |
| Pin an upstream engine/toolchain? | Yes: pin one stable Flutter version per release line; artifacts are per engine revision (already recorded per release) |
| Future upgrades | Per new Flutter version: rebuild engine + `gen_snapshot` + bytecode compiler, re-apply/re-check patches, run the compatibility suite on devices, publish artifacts, then app teams ship a store release. Upstream may change or remove the experimental API without notice **[Verified risk]** |

Recommendation: target **the current Flutter stable at implementation time** for the prototype
(new store release is needed anyway), not 3.44.9. **[Assumption]**

---

## 10. Critical questions

| # | Question | Answer |
|---|---|---|
| 1 | Interpreted patching without our own engine fork? | **No engine *fork*, but a custom engine *build* is unavoidable**: the interpreter is compiled out of stock engines **[Verified]**. flutter_patcher shows the patch set can be small **[Source]** |
| 2 | flutter_patcher as a dependency with our backend? | Technically possible (`applyPatchBytes`/`applyPatchFile` accept bytes from any backend **[Source]**), but it would bring its own envelope, signing, crash logic and Flutter 3.47.x lock-in, plus a single-maintainer artifact supply chain. **Not recommended** beyond a prototype |
| 3 | Reuse its patch-generation tool independently? | Legally yes (MIT); technically it is coupled to its baseline format, managed SDK and artifacts index. Better to reimplement the pipeline using the same upstream tools (`dart2bytecode`, `--dynamic-interface`) |
| 4 | Integrate its runtime into our SDK? | Possible as a `PatchRuntime`, but its native manager would duplicate our verification and state machine. Reimplementing the small Dart/native glue is cleaner |
| 5 | Keep our signing and verification? | **Yes.** ES256 canonical message and keys stay; add native re-verification and protocol v2 `patch_id` |
| 6 | Can installed apps gain interpreter support by OTA? | **No. A new full store release is mandatory** (the interpreter is native engine code) |
| 7 | 1 million DAU? | **Not claimable.** The patch-engine choice does not change backend scaling; the backend has never been load-tested. Downloads come from a CDN/object storage; update checks hit the API (1M DAU × a few checks/day ≈ tens of requests per second on average, higher at peaks) **[Assumption]**. Needs Phase 11 testing |
| 8 | 10,000 simultaneous downloads? | Downloads are static, immutable, content-addressed files served by the CDN/bucket, not the API; load is bandwidth = 10,000 × patch size. Bytecode patches should be smaller than full `libapp.so` diffs **[Assumption]**. Signature checks run on devices, not the server |
| 9 | New Flutter engine version? | A: re-test the flag. B: rebuild engine, `gen_snapshot` and compiler; re-validate; ship a store release. Old releases keep working with their own engine; patches are per engine revision |
| 10 | Independent open-source project without Shorebird? | **Yes for B** (upstream BSD sources + our code). Not for a Shorebird-style iOS interpreter (private). We would host our own engine artifacts |

---

## 11. Migration plan

Estimates are rough, for one experienced engineer, and assume no unexpected upstream blockers
**[Assumption]**. Ranges reflect the experimental status of Dart dynamic modules.

| Phase | Objectives | Components | Dependencies / blockers | Tests | Deliverable | Person-weeks |
|---|---|---|---|---|---|---|
| 1. Research & selection | This report; decide architecture; pick target Flutter version | Docs | Owner decision | — | Approved architecture (ADR) | 1 (done: research) |
| 2. Isolated prototype | Build engine + `gen_snapshot` with `--dart-dynamic-modules` from upstream; load a hand-made bytecode module in a sample app on Android | New `tools/engine/` scripts (separate repo or folder) | Engine build infra (large disk/CPU); upstream VM fixes like flutter_patcher's | Load/run module on device; release mode | Reproducible engine build + demo | 4–8 |
| 3. Build-time patch generation | Bootstrap main, dynamic interface, baseline, package renaming, `dart2bytecode` pipeline | `cli/` (new module), baseline format | Phase 2 | Golden tests on modules; rejection of plugins/FFI | `ota release/patch android --runtime bytecode` | 6–10 |
| 4. Runtime patch loading | `BytecodePatchRuntime`; start patched `main`; assets | `packages/ota_client/lib/src/` | Phase 3 | Unit + device tests; fallback to host code | Runtime in SDK (experimental) | 4–6 |
| 5. SDK integration | API, docs, example, coexistence with A and mock | SDK, example | Phase 4 | Full SDK test suite | SDK release candidate | 2–3 |
| 6. Backend protocol | New format/ABI, policy gate, baseline artifact storage | `backend/app` (schemas, models, admin), migration if needed | Phase 3 | Backend tests; e2e demo | Backend support | 2–3 |
| 7. Signing & security | Native ES256 re-verification; protocol v2 (`patch_id`); threat model update | SDK native + Dart, backend canonical | Phase 4 | Tamper/replay tests | Security review package | 3–5 |
| 8. Rollback & crash recovery | Boot confirmation, Dart-error watch, crash detection, server rollback with bytecode | SDK, native | Phase 4 | Crash-injection tests | Verified fallback paths | 2–4 |
| 9. Flutter compatibility | Engine build per supported version; upgrade playbook; CI for engine builds | `tools/engine/`, CI | Phase 2 | Matrix tests per version | Compatibility matrix | 4–8 |
| 10. Android device testing | Device farm / several devices, ABIs, Android versions | — | Phases 4–8 | Real-device suite | Test report | 3–5 |
| 11. Load & performance | Backend load tests; patch size and interpreter performance benchmarks | Backend, CDN | Phases 6–10 | Load tests, benchmarks | Capacity and performance report | 3–5 |
| 12. Production-readiness | Independent security review, policy review, docs | All | All | External audit | Go / no-go assessment | 3–6 + external audit |
| **Total** | | | | | | **≈ 37–64 pw** + external review (≈ 45–75 pw including integration overhead) |

---

## 12. Strategies and recommendation

| Criterion | **A. Keep AOT replacement** | **B. Bytecode on Dart dynamic modules (own implementation)** | **C. Shorebird-like modified toolchain** |
|---|---|---|---|
| Feasibility | ✅ Exists today | 🟡 Proven by flutter_patcher; experimental upstream feature | ❌ Needs private-level Dart work (iOS) |
| Maintenance burden | 🟡 Low code, fragile flag | 🔴 Engine builds per Flutter version | 🔴🔴 Full fork |
| Policy considerations | 🔴 Native `.so` concern | 🟡 Closer to the interpreter exception; uncertain | 🔴 Android AOT same as A; iOS interpreter separate review |
| Performance | ✅ Full AOT | 🟡 Patched packages interpreted | ✅ / 🟡 |
| Long-term independence | 🟡 Depends on an undocumented engine flag | ✅ Upstream BSD sources, own artifacts | ❌ Practically impossible independently |
| Cost | ✅ Lowest | 🟡 Medium–high | 🔴 Very high |
| Effort | ~0 (maintenance only) | ≈ 45–75 pw | Years with a team **[Assumption]** |
| **Rank** | 2 | **1** | 3 |

**Recommendation: strategy B, implemented independently.** Reasons:

1. It is the only path that is both **independent** (upstream, BSD-licensed Dart interpreter; our own
   engine builds and artifacts) and **open to iOS later** (subject to Apple review).
2. It is the approach with the **better policy position** on Android, while not being automatically
   compliant.
3. Our backend, rollouts, signing and device model already support new formats; only generation and
   execution change.
4. flutter_patcher (MIT) demonstrates the techniques; we learn from it and credit it, but avoid
   depending on a single-maintainer, single-Flutter-version artifact supply chain.

Keep **A** as the experimental option (and for apps that cannot ship a new engine), and do not
pursue **C**.

**Key risks of B:** Dart dynamic modules are experimental and may change or be removed upstream;
patches are package-level and cannot touch Flutter, plugins or FFI; interpreted code is slower; every
Flutter upgrade needs an engine rebuild; a new store release is required for every app that adopts
it.

**Next step if approved:** write an ADR, then Phase 2 (isolated prototype on a pinned Flutter stable).
No implementation starts before that approval.

---

## 13. Sources

| Source | URL | Date / revision |
|---|---|---|
| Google Play Device and Network Abuse | https://support.google.com/googleplay/android-developer/answer/16559646 | Checked 2026-11-12 |
| Google Play SDK Requirements | https://support.google.com/googleplay/android-developer/answer/13323374 | Checked 2026-11-12 |
| Dart SDK `runtime_args.gni` | https://github.com/dart-lang/sdk/blob/main/runtime/runtime_args.gni | main `32c9349`, tag 3.12.2 |
| Dart dynamic modules README | https://github.com/dart-lang/sdk/blob/main/pkg/dynamic_modules/README.md | main `32c9349` |
| Dart `object.cc` (loader) | https://github.com/dart-lang/sdk/blob/main/runtime/lib/object.cc | main `32c9349` |
| Flutter engine `tools/gn` | https://github.com/flutter/flutter/blob/master/engine/src/flutter/tools/gn | master `c08f4b8` |
| Flutter `-ddm` builder | https://github.com/flutter/flutter/blob/master/engine/src/flutter/ci/builders/linux_android_aot_engine_ddm.json | master `c08f4b8` |
| flutter/flutter#14330 (code push) | https://github.com/flutter/flutter/issues/14330 | Open |
| flutter/flutter#162206 (override `libapp.so`) | https://github.com/flutter/flutter/issues/162206 | Closed not planned, 2025-01-25 |
| flutter_patcher | https://github.com/xuelinger2333/flutter_patcher · https://pub.dev/packages/flutter_patcher | `5fb8ff0`, v1.1.0 |
| flutter_patcher_artifacts | https://github.com/xuelinger2333/flutter_patcher_artifacts | `0480e8a` |
| Shorebird system architecture | https://docs.shorebird.dev/code-push/system-architecture/ | Fetched 2026-11-12 |
| Shorebird FAQ | https://docs.shorebird.dev/code-push/faq/ | Fetched 2026-11-12 |
| Shorebird patch signing | https://docs.shorebird.dev/code-push/guides/patch-signing/ | Fetched 2026-11-12 |
| Shorebird updater | https://github.com/shorebirdtech/updater | `4573043` |
| Shorebird CLI | https://github.com/shorebirdtech/shorebird | `4d6a621` |
| Shorebird Flutter fork | https://github.com/shorebirdtech/flutter | `e2c965f` |

Related: [ADR-0001](../adr/0001-runtime-abstraction.md),
[ADR-0011](../adr/0011-scope-and-runtime-path.md),
[iOS runtime research](../roadmap/runtime-ios-research.md),
[policy/google-play.md](../policy/google-play.md),
[platform-compatibility.md](../platform-compatibility.md).
