# Runtime track R — Android engine fork (`aot-bidiff-android-v1`)

**Goal:** an installed Android app (built with *your* Flutter engine) runs new Dart code from a verified patch. If anything goes wrong, it falls back to the store-installed code.

**Why this is a separate track:** this is compiler/engine work, not backend work. It runs **in parallel** with Phases 1–11 (see the master plan). Decision record: [ADR-0011](../adr/0011-scope-and-runtime-path.md).

**Effort:** about 12–20 person-weeks for the first working version. As a beginner, expect around 1.5× that. After that, **every Flutter upgrade** costs about 1–2 pw of rebase and testing. This never goes away.

**New concepts:** Flutter engine source build, `depot_tools`/`gclient`, AOT snapshot (`libapp.so`), ABI (`arm64-v8a`…), binary diff, APK splits.

Every step is **Why / Do / Check**, like the other phases. Many steps here are *research*. Their output is a short report in `docs/runtime/`, not code.

---

## How Android code push works (read this first)

When you run `flutter build appbundle --release`, your Dart code is compiled ahead of time into **one native library per CPU architecture**:

```
app.aab
└── base/lib/arm64-v8a/libflutter.so   ← the Flutter engine (C++)
    base/lib/arm64-v8a/libapp.so       ← ALL your Dart code, compiled
```

At startup, the Java/Kotlin side of the engine (`FlutterLoader`) tells the C++ engine which `libapp.so` to load. The whole trick:

```
store install:  engine loads  <apk>/lib/arm64-v8a/libapp.so            (base)
after patch:    engine loads  <files>/ota/patches/<id>/libapp.so       (patched)
                              └─ only if it is verified, compatible and not marked bad
```

A patch is **not** the new `libapp.so` (that is 5–30 MB). It is a **binary diff** from the base `libapp.so` to the new one, usually much smaller. The phone rebuilds the new file with `base + diff → new`, then checks its hash.

That is exactly what the signed fields in [ADR-0002](../adr/0002-signature-scheme.md) describe:

| Signed field | Meaning on Android |
|---|---|
| `base_artifact_sha256` | Hash of the store-installed `libapp.so` for this ABI |
| `payload_sha256` | Hash of the downloaded diff file |
| `result_sha256` | Hash of the rebuilt `libapp.so`. Checked **before** it is ever loaded |
| `arch` | `arm64-v8a`, `armeabi-v7a` or `x86_64`. One patch artifact per ABI |
| `runtime_abi` | Your engine fork version, e.g. `ota-engine-android-1` |

**What can be patched:** Dart code only (your code and pure-Dart packages).
**What can never be patched:** Java/Kotlin, plugins with native code, `AndroidManifest.xml`, permissions, assets (images, fonts), the Flutter version itself. Those need a store release.

---

## R.0 Store policy gate (do this before writing engine code)

**Why:** Google Play forbids downloading "executable code (such as dex, JAR, .so files)", except code that runs in a VM or interpreter. A patched `libapp.so` is close to that line. You ship to both Play Store and enterprise, so this decides where the runtime may be used.

**Do:**
1. Read the current Google Play *Device and Network Abuse* policy and save the exact text in `docs/runtime/policy-android.md`, with the date.
2. Write down the decision from ADR-0011: `enterprise` apps may use `aot-bidiff-android-v1` immediately. `public_store` apps only after a written legal/policy review.
3. Plan the server rule (implemented in Phase 2/7): publishing an `aot-bidiff-android-v1` patch to an app with `distribution = public_store` fails with `403 policy_review_required`, unless an admin flag `aot_policy_approved = true` is set on that application.

**Check:** `policy-android.md` exists, and the rule is added to Phase 2's compatibility checklist.

---

## R.1 Build the Flutter engine from source (1–2 pw)

**Why:** you cannot change the engine until you can build it unchanged and run an app on it.

**Do:**
1. Machine: Linux, at least 16 GB RAM (32 GB is better), about 100 GB free disk.
2. Since 2025 the engine source lives **inside** the `flutter/flutter` repository (`engine/` folder). Fork `flutter/flutter` on GitHub into your organisation.
3. Follow the official guide: `engine/src/flutter/docs/contributing/Setting-up-the-Engine-development-environment.md` in that repo. In short: install `depot_tools`, copy the provided `.gclient` template, run `gclient sync`.
4. Pick **one** Flutter stable tag (for example the latest `3.x.y`) and check it out. Write it in `docs/runtime/engine-version.md`. All releases in this track use exactly this version.
5. Build the release engine for one ABI (the guide shows the current tool, `et`, or `gn` + `ninja`): `android_release_arm64` plus the matching host build.
6. Build the example app against it with `flutter build apk --release --local-engine=... --local-engine-host=...`.

**Check:** the example app runs on a real arm64 phone. `adb logcat` shows it uses *your* engine (add one log line to `FlutterLoader` to prove it).

---

## R.2 Find where `libapp.so` is chosen (research, 0.5–1 pw)

**Why:** you need the exact place to hook into. It changes between Flutter versions.

**Do:** read these and write `docs/runtime/android-load-path.md`:
- `FlutterLoader.java`: look for `aot-shared-library-name`. It passes the library name and path(s) to the C++ engine as command-line flags.
- The C++ side, where the engine tries each given path in order until one loads.
- `FlutterApplicationInfo` / `ApplicationInfoLoader`: where `nativeLibraryDir` comes from.

Answer in the report:
1. If you pass **two** paths (patched first, then base), does the engine fall back to the second if the first fails to load?
2. Can the engine load a `.so` from the app's private files directory on Android 10+ (the W^X / `targetSdk ≥ 29` exec restrictions)? Test it on a real device, don't assume.

**Check:** the report answers both questions, with logcat evidence.

---

## R.3 Read the base `libapp.so` on the device (0.5–1 pw)

**Why:** to rebuild `base + diff`, the phone needs the exact base bytes. With App Bundles, `libapp.so` is often **not** extracted to disk. It sits uncompressed inside a split APK (e.g. `split_config.arm64_v8a.apk`).

**Do:**
1. On a Play-style install (use `bundletool` to install from the `.aab`), list `applicationInfo.sourceDir` and `splitSourceDirs`.
2. Find which APK contains `lib/<abi>/libapp.so`, and read that zip entry.
3. Compute its SHA-256 on the device and compare it with the hash of `libapp.so` from your build output.

**Check:** hashes match on (a) an APK install and (b) an AAB/bundletool install. Write the method in `docs/runtime/android-base-read.md`.

---

## R.4 Choose and test the diff tool (1 pw)

**Why:** patches must be small. 1M installs × 20 MB is 20 TB per patch. A diff is usually a few hundred KB to a few MB.

**Do:**
1. Candidates: `bsdiff`, or the `patch` crate in [`shorebirdtech/updater`](https://github.com/shorebirdtech/updater) (Apache-2.0 **or** MIT, so reuse is allowed if you keep the licence notice).
2. Experiment: build the app (version A), change one string, build again (B), change one screen (C). Diff A→B and A→C. Record diff sizes and the time to apply on a cheap phone.
3. Note: Dart's compiler can reshuffle a lot of code after a small change, so diffs can be bigger than expected. That is fine on Android, because the whole file is replaced. It only costs bandwidth.

**Check:** `docs/runtime/diff-benchmark.md` with a table of sizes and apply times. Decide the tool, and write it into the `aot-bidiff-android-v1` definition in ADR-0003.

---

## R.5 The engine hook (2–3 pw)

**Why:** this is the one change that makes code push possible.

**Do (design first, then code when you ask for it):**
1. On startup, **before** the engine is initialised, `FlutterLoader` reads the OTA `state.json` (the same file and boot protocol as [Phase 5.7](phase-05-flutter-client.md)).
2. If `active` is a patch whose rebuilt `libapp.so` exists **and** its SHA-256 equals `result_sha256` in the stored, signature-verified manifest **and** its `base_artifact_sha256` equals the installed base → pass the patched path first, then the base path.
3. Otherwise → pass only the base path (normal Flutter).
4. Set `bootAttemptPatchId` before loading. The Dart side calls `markBootSuccessful()` after the first frame plus about 10 seconds (already in Phase 5.7).
5. On the next start, if `bootAttemptPatchId` is still set → mark that patch bad and load the base. This is the crash-loop protection.

Keep the hook **small** (Java, a few dozen lines). All complex logic (download, verify, diff apply) stays in the Dart `ota_client`, or in a small native helper, *outside* the engine. A small hook makes every Flutter upgrade easier.

**Check (all must pass on a real phone):**
- [ ] No patch → app behaves exactly like stock Flutter
- [ ] Valid patch → new Dart code runs after restart
- [ ] Patch file corrupted on disk → base code runs, `patch_hash_failed` is reported
- [ ] Patch that throws in `main()` → second start runs base code, patch marked bad
- [ ] Phone switched off during patch apply → next start runs base or the old patch, never a half-written file

---

## R.6 The `PatchRuntime` for Android (1 pw)

**Why:** the platform only talks to the `PatchRuntime` interface ([ADR-0001](../adr/0001-runtime-abstraction.md)). This makes the engine fork just another runtime.

**Do:** `AndroidAotPatchRuntime implements PatchRuntime`:
- `supportedFormats = {'aot-bidiff-android-v1'}`
- `checkCompatibility`: the device ABI matches `arch`, the engine `runtime_abi` matches, and the installed base `libapp.so` hash (R.3) matches `base_artifact_sha256`
- `stagePatch(verifiedDiff)`: apply the diff into `tmp/`, check `result_sha256`, then atomically rename into `patches/<id>/libapp.so`
- `activateStagedPatch`: only updates `state.json`. The engine picks it up on the **next** start, so the app never swaps code while running
- `rollback`: set `active` back to `lastGoodPatchId` or the base

**Check:** the Phase 5 end-to-end test passes with this runtime instead of the mock runtime.

---

## R.7 Release and patch builder (CLI) (2–3 pw)

**Why:** a person (or CI) must be able to do `release` and `patch`, like `shorebird release` and `shorebird patch`.

**Do:** extend the Phase 4 CLI with two commands:

```
ota release android --version 1.0.0+100
  1. check the Flutter version == engine-version.md
  2. build the .aab with your engine
  3. for each ABI: extract libapp.so → upload as release artifact (sha256)
  4. store the full .aab hash + the list of all its files and hashes ("release manifest")
  5. register the release (flutter/engine revision, runtime_abi) in the API

ota patch android --release 1.0.0+100 --channel dev
  1. download the release manifest + base libapp.so per ABI
  2. build the .aab again from the current code, same engine
  3. COMPATIBILITY CHECK: compare every file except libapp.so with the release manifest.
     Anything different (Java/Kotlin, native libs, manifest, assets) → STOP:
     "native or asset change detected, needs a store release"
  4. for each ABI: diff(base libapp.so → new libapp.so) → payload
  5. hash → sign (Phase 6) → upload (Phase 4) → create patch as draft
```

**Check:** changing only Dart code creates a patch. Changing an image, adding a plugin, or changing `AndroidManifest.xml` is **rejected** with a clear message.

---

## R.8 Ship the engine to CI (1–2 pw)

**Why:** CI (Phase 10) must build releases with your engine without compiling it every time (an engine build takes 1+ hour).

**Do:** research and pick one, and write it as ADR-0012:
- (a) Build the engine once per Flutter version and upload the artifacts to private Azure Blob. Point the Flutter tool at them (Flutter supports a custom artifact host through `FLUTTER_STORAGE_BASE_URL`; Shorebird uses the same idea with its artifact proxy).
- (b) A prebuilt CI container image that already contains the engine build (simpler, but huge).

**Check:** a clean GitHub Actions runner builds a release AAB with your engine in under 20 minutes.

---

## R.9 Version upgrade runbook

**Why:** every new Flutter version needs your hook moved onto it. If this is not written down, it gets forgotten.

**Do:** `docs/runtime/upgrade-runbook.md`: rebase the fork → rebuild → re-run every R.5 check → new `runtime_abi` value → publish engine artifacts → only *new* releases use it. Old releases keep their old engine forever. Their patches must be built with the old engine, so **keep old engine builds available** for as long as old app versions are in use.

**Check:** do one practice upgrade (current stable → next patch version) using only the runbook.

---

## Track R is done when

- [ ] A real Dart bug fix reaches a phone through the full pipeline: build → sign → rollout → device → runs
- [ ] All R.5 failure checks pass
- [ ] Native/asset changes are rejected by the CLI
- [ ] Policy gate enforced: `public_store` apps cannot receive AOT patches without approval
- [ ] One Flutter upgrade done using the runbook

Then, and only then, start [iOS research](runtime-ios-research.md).
