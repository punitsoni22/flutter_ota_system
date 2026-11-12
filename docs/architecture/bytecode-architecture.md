# Bytecode patch engine (research)

A short public summary of the proposed next patch engine for Flutter OTA System: what it is, what
the research prototypes measured, and what does **not** exist yet.

> [!IMPORTANT]
> **Research only.** Nothing on this page is part of the `flutter_ota_system` SDK, the backend or
> the CLI today. The evidence comes from research prototypes run on **one physical Android 13
> arm64 phone**, in release mode, with **one pinned Flutter version** (3.47.9, Dart 3.13.7) and a
> **custom Flutter engine build**. Nothing is verified for other devices, ABIs, Flutter versions,
> iOS, macOS, Windows or the web. No store approval or production readiness is claimed. This is
> not legal advice.

## Why a new engine

The experimental Android code patches in v0.1.0-alpha.1 download a new native `libapp.so` and
load it at start ([platform-compatibility.md](../platform-compatibility.md)). That approach is a
significant Google Play policy risk ([policy/google-play.md](../policy/google-play.md)), relies on
an engine flag Flutter does not support for this purpose, and cannot work on iOS.

The proposed engine instead compiles changed Dart packages to **Dart bytecode** and runs them with
the Dart VM's **interpreter** ("Dart dynamic modules", an experimental upstream feature). The rest
of the app stays ahead-of-time (AOT) compiled. The backend, database, signing, channels, rollouts
and rollback stay as they are; only patch generation and patch execution change.

Decision record: [ADR 0001 (architecture series)](adr/0001-bytecode-engine-and-developer-experience.md)
(status: **Proposed**, not approved for implementation).

## How it works (prototype)

```
store build   pinned Flutter + custom engine (interpreter compiled in) → APK + baseline
patch         changed pure-Dart packages → renamed copies → dart2bytecode → validated module
device        verify → load module with the Dart VM interpreter → patched code runs as bytecode
failure       boot not confirmed or load error → back to the baseline AOT code
```

- **Custom engine required.** Stock Flutter engines are built without the interpreter. The
  prototypes use an engine built from unmodified upstream source with the official GN flag
  `--dart-dynamic-modules`. Adopting it needs a new store release.
- **Package-level patches.** A module can only add code, so a patch carries a renamed copy of each
  changed package, and the app calls it through an indirection.
- **Host-owned contracts.** Shared models, state and interfaces stay in the store build. Changing
  them needs a store release.

## What the prototypes measured

Measured on the one test phone ([compatibility matrix](bytecode-compatibility-matrix.md)):

| Area | Result |
|---|---|
| Replacing pure-Dart app packages, several at once, and pure-Dart dependencies | Works, with restrictions |
| Visible UI changes, navigation, `FutureBuilder`/`StreamBuilder`, animations, form validation | Works |
| 49 Dart language features tested | Same result as AOT when interpreted |
| Crash recovery (throws, aborts before/after the first frame, damaged files) | Always back to the baseline; no crash loop seen |
| FFI (`dart:ffi`) in a module | **Unsafe:** compiles, then aborts the process. Must be refused |
| Malformed bytecode that passes file checks | **Aborts the process.** Signature verification before loading is mandatory |
| Dynamic calls into the host | Refused by default; when allowed, returned a wrong value. Must stay forbidden |
| Performance | Interpreted CPU-bound code 1.5–165× slower than AOT; about 19 ms (4 %) extra cold start for a 15.5 KB patch |
| App size | Exposing the full Flutter interface made `libapp.so` about 4.3× larger in the test app |

## What does not exist yet

- Signature verification before a module is loaded (the prototypes check integrity only).
- A patch generator for arbitrary apps, and SDK, CLI and backend integration (new artifact format).
- **Automatic local toolchain management** (downloading a pinned engine and compiler bundle).
  Planned; the prototypes use manual scripts.
- Testing on any other device, ABI or Flutter version.
- iOS: out of scope.

## Where the evidence is

- [ADR 0001 (architecture series)](adr/0001-bytecode-engine-and-developer-experience.md): the
  decision, the target design and the open risks.
- [bytecode-compatibility-matrix.md](bytecode-compatibility-matrix.md): what a module can and
  cannot change.
- [phase-1-prototype-report.md](phase-1-prototype-report.md) and
  [phase-2-compatibility-report.md](phase-2-compatibility-report.md): the detailed engineering
  reports.
- [prototypes/](../../prototypes/README.md): the research prototypes and their recorded results.
