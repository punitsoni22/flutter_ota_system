# Redirect stubs: adaptive OTA patch levels (local proof)

Research prototype for shipping **any Dart change** as an OTA patch whose size and cost follow
the size of the change. Not product code.

## Idea in one paragraph

Dart's bytecode interpreter can only *add* code, never replace it. So the store build is prepared
in advance:
- every app function, and every global/static/instance initializer, gets a hidden **slot** and a
  cheap check ("has a patch replaced me?");
- a patch carries only what changed; at start-up it fills the slots.

Unchanged code keeps running compiled. Changes that can't be expressed by replacing bodies use the
next mechanism up: re-pointed call sites, side fields, class copies, or a whole-app copy.

```dart
// store build (generated, invisible to developers)
int total() { final ota$f = ota$s1a2b3c4d5; if (ota$f != null) return ota$h1a2b3c4d5(ota$f);
  ...original body... }
int Function(Cart self)? ota$s1a2b3c4d5;               // typed slot, kept by the optimizer
// patch (generated from the v1 -> v2 difference)
int ota$r1a2b3c4d5(Cart self) => self._sumPositive() - self.ota$p_discount * 2;
```

## What is here

| Path | What |
|---|---|
| `cases/v1`, `cases/v2` | Test app before/after: 53 cases, one kind of change each |
| `tool/` | `ota_redirect`: `instrument` (store build) and `patch` (v1 → v2 patch libraries) |
| `run_shot1.py` | Builds everything with the real Dart AOT compiler, compares with the real v2 in three patch modes, checks the optimizer, measures speed/size |
| `out/` | Generated (git-ignored): builds, `shot1_report.md`, `shot1_results.json` |
| `shot2/` | The same cases on a real Android phone through the real CLI, server and interpreter, with five store-build modes, a patch chain, crash-protection tests and a patch size ladder: see [shot2/SHOT2.md](shot2/SHOT2.md) |

## In the CLI (EXPERIMENTAL)

`flutter_ota_cli` has a second patch engine that uses this tool (`FLUTTER_OTA_REDIRECT_TOOL` must
point at `tool/`):

- `flutter_ota release android --engine redirect [--skip-leaves]` instruments the build copy
  before the dynamic interface, `link.dill` and the store build are made, and keeps a baseline in
  `.flutter_ota/releases/<id>/redirect/` (source as built, instrumented source, slot manifest).
- `flutter_ota patch android` sees the release's engine and, for `redirect`, runs
  `ota_redirect patch --module ota_patch_<n>`, guards the module package against the
  instrumented source, compiles it against `link.dill`, verifies, signs and uploads it like any
  patch. A change the tool refuses stops with its reasons (exit 3).
- Private classes, mixins and enums that patches reach through the tool's type aliases are listed
  by name in the store build's dynamic interface (a library entry covers public declarations
  only); the tool records them in its manifest (`private_types`).
- EXPERIMENTAL, hidden: `release android --engine redirect --interface-scope app` lists only the
  app package and the safe `dart:` libraries in the interface, to measure what the interface
  costs. Patches can then use only the app's own code directly.

## Run

```bash
python3 run_shot1.py            # uses `dart` on PATH; or: --dart /path/to/dart
open out/shot1_report.md
```

Needs only a stock Dart/Flutter SDK. No custom engine is involved: the patch is linked in and
installed at start-up to *simulate* loading the bytecode module. Loading through the real
interpreter on a device is the next step.

## Patch mechanisms and levels (chosen per declaration)

| Mechanism | Ships | Level |
|---|---|---|
| Body replacement | changed bodies of functions, methods, getters, setters, operators (incl. async/async*/sync*, generics, extensions, enums, mixins, private members, closures, records/patterns, `super` calls) | 1 |
| Constant users | unchanged functions using a changed constant | 1 |
| Initializer slots | changed initializers of globals, static fields and instance fields | 1 |
| Additions | new files, classes, functions, members and static constants | 2 |
| Call-site re-pointing | signature and default-value changes, changed tiny leaves (fast mode), variables whose type changed | 2 |
| Side fields | new fields on existing classes, incl. new constructor parameters (constructor helper) | 2 |
| Widget copy | widget classes that gained fields | 2 |
| Class copy | new enum values, class header changes, new overrides, field type changes | 3 |
| Whole-app copy (`--critical`) | everything in `lib/` | 4 |
| Store release | native code, Flutter/Dart version, new native plugins | — |

`patch` prints the level and size, for example:
`PATCH LEVEL 3: 14 files, +115/-68 lines -> 76 functions interpreted, 6 class copies, ...`

## Modes

- **normal:** every function has a check.
- **fast** (`instrument --skip-leaves`): tiny one-expression leaf functions have no check, which
  removes their cost in hot loops; a change to one re-points its callers instead.
- **critical** (`patch --critical`): the whole app ships as a copy.

## Known limits

- **Background isolates:** slots are per isolate. In this local simulation, background code can
  see patched code; on a device this depends on how the loaded bytecode is shared (Shot 2 cases
  `c43_isolate`, `c43c_isolate_run_tearoff` and `c43d_isolate_spawn` check it).
- **Crash protection:** the SDK counts a Dart error against a patch only after a feature slot of
  the feature engine was used, so a Dart error from a redirect patch does not roll it back yet
  (process crashes do). Shot 2 measures both.
- **Whole-app copy (level 4)** works in the local simulation only; on a device it needs the SDK
  to run the patch's `main` instead of the store one. The CLI does not offer it yet.
- **Only the app package** is instrumented and patched. A change in a dependency (including a
  local path package) needs a store release with this engine.
- **The dynamic interface is the main speed/size cost** of any patchable store build. See the
  performance section of `out/shot1_report.md`.
- Saved data must stay backward compatible across patches and rollbacks (a release rule, not a
  tool feature).
