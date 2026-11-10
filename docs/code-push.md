# Dart code patches (Android)

Change Dart code, run one command, and phones run the new code after their next restart. No store
review. Works with stock Flutter (no engine fork), the same way Shorebird does it on Android.

## How it works

`flutter build` compiles all your Dart code into one file per CPU type: `lib/<abi>/libapp.so`.

```
your laptop                       server                     phone
───────────                       ──────                     ─────
ota patch android                 stores + signs the diff    downloads the diff (KBs)
  builds the app again              (ES256)                  rebuilds libapp.so = store file + diff
  checks only Dart changed                                   checks base hash, result hash, signature
  diffs new libapp.so against                                saves it in the app's private folder
  the release's (bsdiff)                                     next start: OtaBoot (Java) tells Flutter
                                                               to load it, before any Dart runs
```

Stock Flutter lets an app load its `libapp.so` from the app's own files folder
(`--aot-shared-library-name`). `OtaBoot.java` sets that at process start, from a content provider,
so every Flutter engine in the process (UI, push handlers, background jobs) runs the same code.

**Crash protection.** When a new patch starts with UI, OtaBoot records an "attempt". The app
confirms the patch 5 seconds after its first frame. An attempt that is still unconfirmed on the next
start means the patch crashed or was killed: OtaBoot skips it for good, runs the last good patch (or
the store code), and the app reports `patch_boot_failed` to the server. A process woken for a push
or a background job never counts as an attempt.

**What a patch can change:** Dart code, including pure-Dart packages.
**What needs a store release:** Flutter version, plugins with native code, Java/Kotlin, the manifest,
resources, and assets (images, fonts, `.env`). `ota patch android` checks all of these and refuses.

## Add it to an app (once)

1. `pubspec.yaml`:
   ```yaml
   ota_client:
     path: ../flutter_ota_system/packages/ota_client   # or a git dependency
   ```
2. Start it after the first frame :
   ```dart
   final ota = OtaClient(OtaConfig(
     serverUrl: 'https://ota.example.com',
     appSlug: 'my-app',
     releaseVersion: '${info.version}+${info.buildNumber}',
     publicKeys: {'prod-1': '<public key from `ota key show`>'},
     runtime: AotPatchRuntime(),
   ));
   await ota.boot();
   ota.markBootSuccessfulAfterFirstFrame(stableFor: const Duration(seconds: 5));
   ota.checkForUpdate();
   ```
   Nothing else: no change to `MainActivity`. The plugin's manifest adds the boot provider.
3. Register the app: `ota app create my-app "My App" --distribution public_store`.
   Play Store apps also need `ota app approve-policy my-app --reason "..."` before the first code
   patch is published. That records who accepted the policy question (see below).

## Every store release

Run in the Flutter project folder. Everything after `--` goes to `flutter build` unchanged.

```bash
ota release android my-app -- --dart-define=API_BASE_URL=https://api.example.com
```

It builds the AAB (`--kind apk` for a directly installed test build), registers the version from
`pubspec.yaml`, and uploads the compiled code and a fingerprint of everything else. **Upload exactly
that file to Play.** Patches are diffs against it, so a rebuilt file needs a new `ota release`.

By default it adds `--no-tree-shake-icons`: the full icon font ships with the app, so a patch may use
icons the release did not (otherwise the font asset changes and the patch is refused).
`--tree-shake-icons` turns that off.

## Every fix

```bash
# change Dart code, then:
ota patch android my-app --channel staging --note "fix checkout total"
```

It rebuilds with the release's exact build arguments, refuses non-Dart changes, diffs each ABI and
publishes to `staging`. Testers' phones get it on their next check, and run it after a restart.
Then, from the admin page or the CLI:

```bash
ota patch promote <patch_id> --percent 10     # production, refused if staging saw boot failures
ota patch rollout <patch_id> --channel production --percent 100
ota patch rollback <patch_id>                 # devices go back to the previous patch
ota patch revoke <patch_id> --yes             # never again, anywhere
```

**Ten changes on main, one fix to ship:** a patch is always the whole app as the code is now. Build
it from a branch that has only the fix: `git switch -c hotfix v9.0.56` (the release tag),
`git cherry-pick <fix>`, `ota patch android ...`, then switch back.

## Play Store policy

Google Play forbids downloading executable code "such as dex, JAR, .so files", except "code that
runs in a virtual machine or an interpreter". Code push tools for Flutter (Shorebird) rely on the
exception: the patch is Dart AOT code that the Dart VM inside Flutter runs; no Java/Kotlin/native
code is ever downloaded. Google has not ruled on it publicly; it is the same position as Shorebird's.
Stay inside it: Dart-only fixes (the CLI enforces that), no change of the app's purpose through a
patch, and staged rollouts. The server refuses code patches for `public_store` apps until
`ota app approve-policy` records who accepted this.

## Limits

- Android only. iOS needs an interpreter (Apple forbids new compiled code); not built.
- The patch must be built with the same Flutter as the release (checked).
- Patch size is the binary diff: a few KB for small changes, more when much code moves.
- Debug builds ignore code patches (they run Dart in JIT mode).
