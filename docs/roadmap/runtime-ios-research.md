# Runtime track R-iOS — iOS code push research

> **Roadmap status: 🔭 research only.** Flutter OTA System has **no iOS code patch support**. These notes compare
> options; none has been built or tested.

**Start only after** [Track R (Android)](runtime-android-engine.md) is done. This is research, so the output is reports and a decision, not a product. Decision record: [ADR-0011](../adr/0011-scope-and-runtime-path.md).

---

## Why iOS is so much harder

On iOS, Apple does not allow an app to load native machine code it downloaded. Code signing enforces this, so the Android trick (load a new `libapp.so`) is **technically impossible** on iOS, not just a policy problem.

The only way is to run the changed Dart code in an **interpreter**. Shorebird does this with:
1. a Dart interpreter added to the engine,
2. a compiler that keeps the new build as similar as possible to the old one,
3. a **linker** that runs each unchanged function from the original fast native code, and only the changed functions in the interpreter (Shorebird says typically ≥98% stays native).

Parts 1–3 live in Shorebird's **Dart SDK fork, which is private**. Its engine fork and updater are public.

---

## I.1 Policy review first (0.5 pw)

**Do:** save the current Apple App Review Guideline 2.5.2 and the Developer Program License Agreement text on interpreted code in `docs/runtime/policy-ios.md`, with the date. Get a legal opinion **before** any iOS user receives a patch. Enterprise/MDM distribution has fewer restrictions, but still no native code download.

---

## I.2 Compare the three options (1–2 pw)

**Do:** spend a few days on each and write `docs/runtime/ios-options.md` with the results:

| Option | What you'd build | Expected effort | Main risk |
|---|---|---|---|
| **A. Own interpreter + linker** | Fork the Dart SDK, add bytecode interpreter + function-level linking | 40–100+ pw, expert compiler work | May never reach production quality |
| **B. Interpreted subset** (`dart_eval` / `flutter_eval`) | Mark some widgets/functions "patchable"; ship `.evc` bytecode, format `evc-v1` | 8–18 pw | Only pre-marked code can change, and not every Dart/Flutter feature works |
| **C. Shorebird toolchain + your server** | Use Shorebird's CLI/engine, point `base_url` (app) and `SHOREBIRD_HOSTED_URL` (CLI) at your backend, implement their patch-check API (`/api/v1/patches/check`, `/api/v1/patches/events`) | 6–10 pw backend | Depends on Shorebird's private binaries and their licence/terms. **Ask Shorebird in writing** before choosing this |

**Spike for option B:** in a throwaway app, make one screen replaceable with `flutter_eval`. List what fails (widgets, packages, async, generics).

**Spike for option C:** build one iOS release with Shorebird's tools and send its patch check to a local mock server. This proves the protocol. Don't ship it until the licence answer is in.

**Check:** `ios-options.md` ends with **one** recommended option and the reasons. Record it as a new ADR.

---

## I.3 Whatever you pick: the same platform

The backend, signing, rollout and boot protocol don't change. The iOS runtime is just another `PatchRuntime` with its own `artifact_format` (`evc-v1`, or a new `ios-interp-v1`). If you choose option C, you add a thin compatibility layer that translates Shorebird's patch-check request into your own update-check logic.
