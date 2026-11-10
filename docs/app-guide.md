# App guide: set up an app, ship store releases, send code patches

For developers who want Dart code fixes in a Flutter Android app to reach phones without a
Play Store update. The OTA server is already running at **https://ota.example.com**
(hosting: [setup-guide.md](setup-guide.md), Part A).

1. [How it works in 1 minute](#1-how-it-works-in-1-minute)
2. [Set up your computer (once)](#2-set-up-your-computer-once)
3. [Add OTA to an app (once per app)](#3-add-ota-to-an-app-once-per-app)
4. [Register the app on the server (once per app)](#4-register-the-app-on-the-server-once-per-app)
5. [Make a store release](#5-make-a-store-release)
6. [Install the build for testing](#6-install-the-build-for-testing)
7. [Send a code patch](#7-send-a-code-patch)
8. [See it on the phone](#8-see-it-on-the-phone)
9. [Staging → production](#9-staging--production)
10. [Roll back or revoke](#10-roll-back-or-revoke)
11. [Ship one fix while main has other work](#11-ship-one-fix-while-main-has-other-work)
12. [The next store release](#12-the-next-store-release)
13. [Admin page](#13-admin-page)
14. [Cheat sheet](#14-cheat-sheet)
15. [Problems](#15-problems)

---

## 1. How it works in 1 minute

- A **release** is one store build: one version (e.g. `9.0.56+407`), one exact APK/AAB. You
  register it with `ota release android` when you build it.
- A **patch** is a fix for one release: your new Dart code, sent as a small diff (KBs). It never
  applies to another version.
- **Channels**: a patch goes to `staging` (testers) first, then `production` (everyone), at any %.
- A phone **downloads** a patch in the background, and **runs** it the next time the app starts.
  Code never changes while the app is open.
- If a patched app crashes on start, the phone goes back to the previous good code by itself, and
  the admin page shows the patch as crashing.

**A patch can change:** any Dart code, including pure-Dart packages.
**Needs a store release:** images, fonts and other assets, `.env`, adding or updating plugins,
Kotlin/Java, `AndroidManifest.xml`, the Flutter version. The patch command refuses these.

Android only for now.

---

## 2. Set up your computer (once)

You need: the same **Flutter version** as everyone who builds the app (`flutter --version`),
Python 3, Git access to `punitsoni22/flutter_ota_system`, and the **admin key** (ask the server owner;
it is `OTA_ADMIN_API_KEY` in `deploy/cloud.env`).

```bash
git clone https://github.com/punitsoni22/flutter_ota_system.git ~/Desktop/flutter_ota_system
cd ~/Desktop/flutter_ota_system
git switch feature/code-push-cloud          # until it is merged into main
python3 -m venv .venv
.venv/bin/pip install -r cli/requirements.txt
```

Add the `ota` command and the server settings to your shell:

```bash
cat >> ~/.zshrc <<'EOF'
# Flutter OTA
alias ota="$HOME/Desktop/flutter_ota_system/.venv/bin/python $HOME/Desktop/flutter_ota_system/cli/ota.py"
export OTA_API_URL=https://ota.example.com
export OTA_API_KEY=<admin key>
export OTA_PUBLIC_KEY='cloud-1:BO+d+Y7E5oLjZQGAuR0iTYgMqMQ6+RStvgYkmGPcQm/yynxCs2OfsQOi55hMZ6k13GKDRsE2xj8fELPX/N3M0qk='
EOF
source ~/.zshrc
```

**Check:** `ota app list` prints a list (maybe `[]`).

If a command waits about a minute and then works, the free server was asleep. That's normal.

---

## 3. Add OTA to an app (once per app)

Pick the app's **slug**: lowercase with dashes, e.g. `shop-app`. It must be the same everywhere
below.

### 3.1 Dependencies

`pubspec.yaml`:

```yaml
dependencies:
  package_info_plus: any            # skip if the app already has it
  ota_client:
    git:
      url: https://github.com/punitsoni22/flutter_ota_system.git
      path: packages/ota_client
      ref: feature/code-push-cloud  # later: main, or a version tag
```

```bash
flutter pub get
```

### 3.2 The OTA file

Create `lib/ota_updater.dart`, and change `_appSlug`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ota_client/ota_client.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Over-the-air Dart code patches (flutter_ota_system).
///
/// Which code runs is decided natively before Dart starts, so nothing here blocks startup:
/// [start] runs after the first frame, confirms the running patch once the app is stable,
/// and downloads a newer one in the background. A downloaded patch runs on the next app start.
///
/// Build-time settings (`--dart-define`):
///   OTA_SERVER_URL  the OTA server. Empty = OTA off.
///   OTA_PUBLIC_KEY  "key_id:base64_point" from `ota key show`. Patches are refused without it.
///   OTA_CHANNEL     default channel of this build (production).
class OtaUpdater {
  OtaUpdater._();

  static const _serverUrl = String.fromEnvironment('OTA_SERVER_URL');
  static const _publicKey = String.fromEnvironment('OTA_PUBLIC_KEY');
  static const _channel = String.fromEnvironment('OTA_CHANNEL', defaultValue: 'production');
  static const _appSlug = 'shop-app'; // ← your app's slug

  static OtaClient? _client;

  /// The patch running now (null = the store build), once [start] has run.
  static PatchRecord? get activePatch => _client?.activePatch;
  static String get channel => _client?.channel ?? _channel;

  static Future<void> start() async {
    if (_serverUrl.isEmpty || _client != null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      final key = _publicKey.split(':');
      final client = OtaClient(OtaConfig(
        serverUrl: _serverUrl,
        appSlug: _appSlug,
        channel: _channel,
        releaseVersion: '${info.version}+${info.buildNumber}',
        publicKeys: key.length == 2 ? {key[0]: key[1]} : const {},
        runtime: AotPatchRuntime(),
      ));
      await client.boot();
      _client = client;
      client.markBootSuccessfulAfterFirstFrame(stableFor: const Duration(seconds: 5));
      final result = await client.checkForUpdate();
      debugPrint('OTA: running patch ${client.activePatchNumber}, check: $result');
    } catch (e, st) {
      debugPrint('OTA: start failed: $e\n$st');
    }
  }

  /// Testers: "staging" gets patches before production. Null = back to this build's default.
  static Future<UpdateResult?> setChannel(String? channel) async {
    final client = _client;
    if (client == null) return null;
    await client.setChannel(channel);
    return client.checkForUpdate(force: true);
  }

  static Future<UpdateResult?> checkNow() async => _client?.checkForUpdate(force: true);
}
```

### 3.3 Start it

In `main.dart`, right after `runApp(...)`:

```dart
import 'ota_updater.dart';

// ...
runApp(const MyApp());
WidgetsBinding.instance.addPostFrameCallback((_) => OtaUpdater.start());
```

It runs after the first frame and never delays startup or throws.

**Nothing else:** no `MainActivity` change and no new permissions (the app needs `INTERNET`,
which almost every app has). The package's Android part adds itself.

### 3.4 Commit

```bash
git add pubspec.yaml pubspec.lock lib/ota_updater.dart lib/main.dart
git commit -m "feat: OTA code patches"
```

---

## 4. Register the app on the server (once per app)

```bash
ota app create shop-app "Shop" --distribution public_store
ota app approve-policy shop-app --reason "Dart-only code patches; approved by <name>"
```

- `--distribution public_store` for Play Store apps, `enterprise` for in-house apps.
- `approve-policy` records who accepted the Play policy question (code patches use the same
  approach as Shorebird). Until it is run, the server won't publish code patches for a
  `public_store` app.

---

## 5. Make a store release

Every build you give to anyone (Play, testers) must be registered, because patches are diffs
against that exact build. Run this in the app's folder, from clean, committed code.

```bash
cd ~/path/to/shop_app
git status                          # nothing uncommitted
```

**Build flags.** Everything after `--` goes to `flutter build`. Always add the three OTA flags,
plus the app's own flags:

| Flag | Value |
|---|---|
| `--dart-define=OTA_SERVER_URL=` | `https://ota.example.com` |
| `--dart-define=OTA_PUBLIC_KEY=` | `$OTA_PUBLIC_KEY` |
| `--dart-define=OTA_CHANNEL=` | `staging` for tester builds. Leave it out for Play (default `production`). |

### 5a. Tester build (APK you install directly)

```bash
ota release android shop-app --kind apk -- \
  --dart-define=OTA_SERVER_URL=https://ota.example.com \
  --dart-define=OTA_PUBLIC_KEY=$OTA_PUBLIC_KEY \
  --dart-define=OTA_CHANNEL=staging \
  --dart-define=API_BASE_URL=https://staging-api.example.com       # app's own flags
```

### 5b. Play Store build (AAB)

```bash
ota release android shop-app -- \
  --dart-define=OTA_SERVER_URL=https://ota.example.com \
  --dart-define=OTA_PUBLIC_KEY=$OTA_PUBLIC_KEY \
  --dart-define=API_BASE_URL=https://api.example.com
```

It takes 3–6 minutes and ends with:

```
Release 1.0.0+1 registered for 'shop-app' (arm64-v8a, armeabi-v7a, x86_64).
Ship exactly this file (store upload or install): .../app-release.aab
```

- **Upload exactly that file** to Play Console. Don't rebuild it.
- The version comes from `pubspec.yaml` (`version: 1.0.0+1`).
- The command saves your build flags; patches reuse them automatically.
- It adds `--no-tree-shake-icons`, so patches can use any Material icon.

**Tag the code of every store release**, so you can patch it later (section 11):

```bash
git tag v1.0.0+1 && git push origin v1.0.0+1
```

One version holds one build. A tester APK and a Play AAB of the same version are two different
builds: give the tester build its own build number (e.g. `1.0.0+1001`), or test with the Play
build itself through Play's internal testing track.

---

## 6. Install the build for testing

| Where | How |
|---|---|
| Emulator / phone on USB | `adb install -r build/app/outputs/flutter-apk/app-release.apk` |
| Testers elsewhere | Send the APK (Drive, Slack, Firebase App Distribution). They allow "install unknown apps". |
| Play build | Play Console → Internal testing → upload the AAB → add testers |

Open the app once. Within seconds it shows on the admin page under **Devices**.

> Don't `flutter run` and don't reinstall a rebuilt APK over a tester's install. A rebuilt APK is
> a different build: old patches won't apply to it, and the phone runs the plain store code.

---

## 7. Send a code patch

1. Change Dart code, e.g. a text or a bug fix.
2. In the app's folder:

```bash
ota patch android shop-app --channel staging --note "fix: checkout total"
```

What it does:

1. Finds the release from `pubspec.yaml`'s version.
2. Rebuilds the app with that release's build flags.
3. Refuses if anything other than Dart changed, and lists what changed.
4. Makes a diff per CPU type and checks it.
5. Uploads it, and the server signs it.
6. Publishes it to `staging`.

It ends with:

```
  arm64-v8a: libapp.so 13.8 MB → patch 42 KB (5s)
  ...
Patch #1 for 1.0.0+1: published to staging at 100%. id bcd8ebac-…
```

Options:

- `--channel` left out: the patch is saved as a **draft**; publish it from the admin page.
- `--percent 20`: only 20% of the channel.
- `--release 1.0.0+1`: patch a release other than `pubspec.yaml`'s version.

Commit the fix as usual.

---

## 8. See it on the phone

Phones built with `OTA_CHANNEL=staging` get staging patches:

1. **Close the app fully** (recent apps → swipe it away), open it, and wait about **10 seconds**.
   It downloads the patch. The screen doesn't change yet.
2. **Close it fully again, and open it.** The new code runs.

On the admin page the patch shows **Boot ok** going up. A patch counts as OK once the app has run
for 5 seconds after its first screen.

Real users get patches the same way: on any app start, plus every 30 minutes while the app is
open, then the next time they open the app.

---

## 9. Staging → production

When staging looks good:

```bash
ota patch list shop-app --platform android --release 1.0.0+1     # shows each patch's id
ota patch promote <patch-id> --percent 10                        # 10% of production phones
ota patch rollout <patch-id> --channel production --percent 50
ota patch rollout <patch-id> --channel production --percent 100
```

Or use the admin page: **Promote to production**, then **Set %**.

- `promote` refuses a patch that was never on staging, or that crashed on any phone.
- The same signed file goes to production. Nothing is rebuilt.
- Phones stay in their % group, so raising 10% → 50% keeps the first 10%.

---

## 10. Roll back or revoke

| | Command | Effect |
|---|---|---|
| **Roll back** | `ota patch rollback <patch-id>` | Phones on it go back to the previous patch (or the store code). It can be published again later. |
| **Revoke** | `ota patch revoke <patch-id> --yes` | Same, and it can never run again anywhere. |

Phones learn about it on their next check (next app start, or within 30 minutes). Like a patch,
the change applies on the start after that.

**Crashing patches roll themselves back** on each phone. The admin page marks them **Crashing**:
revoke them.

---

## 11. Ship one fix while main has other work

A patch is always the whole app as your code is now. If `main` has unfinished work, build the
patch from a branch made from the release's tag:

```bash
git switch -c hotfix/1.0.0+1-checkout v1.0.0+1     # code exactly as shipped
git cherry-pick <commit with the fix>                # only the fix
ota patch android shop-app --channel staging --note "checkout fix"
git switch main
```

The next patch for that release is built from that branch again: patch #2 = tag + fix 1 + fix 2.

---

## 12. The next store release

When you ship a new version (`1.1.0+2`):

1. Bump `version:` in `pubspec.yaml`.
2. Run `ota release android shop-app ...` (section 5), and tag it.
3. Upload it.

Patches belong to one release: phones that update from the store start fresh on `1.1.0+2`, and
`1.0.0+1` patches never reach them. Phones still on `1.0.0+1` keep getting `1.0.0+1` patches.

Remove a test release you no longer need:

```bash
ota release delete shop-app --version 1.0.0+1001
```

No published patch is allowed: roll back first.

---

## 13. Admin page

**https://ota.example.com/admin** → enter the admin key → **Connect**.

- **Apps** → pick the app → a tab per release.
- **Patches**: status, rollout per channel, **Boot ok / Boot failed**, **Crashing** warnings, and
  the buttons Promote / Set % / Publish / Roll back / Revoke.
- **Devices**: how many phones run each version / channel / patch.
- **New app** / **New release**: also possible here, but code patches need the CLI
  (`ota release android`, `ota patch android`), which builds and diffs the app.

---

## 14. Cheat sheet

| Task | Command |
|---|---|
| Check connection | `ota app list` |
| New app | `ota app create <slug> "<Name>" --distribution public_store` |
| Allow code patches | `ota app approve-policy <slug> --reason "..."` |
| Tester release | `ota release android <slug> --kind apk -- <flags incl. OTA_CHANNEL=staging>` |
| Play release | `ota release android <slug> -- <flags>` |
| List releases | `ota release list <slug>` |
| Delete test release | `ota release delete <slug> --version <v>` |
| Code patch → staging | `ota patch android <slug> --channel staging --note "..."` |
| List patches | `ota patch list <slug> --platform android --release <v>` |
| Patch details | `ota patch show <id>` |
| To production | `ota patch promote <id> --percent 10` |
| Change % | `ota patch rollout <id> --channel production --percent 100` |
| Undo | `ota patch rollback <id>` |
| Never again | `ota patch revoke <id> --yes` |
| Public key for apps | `ota key show` |

---

## 15. Problems

| Message / symptom | Fix |
|---|---|
| `zsh: command not found: ota` | `source ~/.zshrc` (section 2) |
| `error 401` | `OTA_API_KEY` missing or wrong |
| Command waits ~1 min | Free server waking up; just wait |
| `policy_review_required` | `ota app approve-policy <slug> --reason "..."` |
| `Release ... already exists` | That version is registered: delete it (test builds) or bump the build number |
| `no android release <v>` | Run `ota release android` first, or pass `--release <v>` |
| `this change needs a store release` | Something other than Dart changed (listed). Revert it, or make a new release |
| `assets changed` | An image, font, `.env` or similar changed: needs a new release |
| `Flutter changed` | Switch to the Flutter version of the release (`flutter --version` vs the release) |
| `Nothing to patch` | The Dart code equals the release: nothing to send |
| Phone never gets the patch | Built with the 3 OTA flags? On the patch's channel (staging vs production)? A release build (debug ignores patches)? Installed the exact registered APK? Logs: `adb logcat \| grep -E "OtaBoot\|OTA:"` |
| Patch appears, then is gone after a restart | It crashed, or the app was closed within 5 s of opening it. Admin page: Boot failed |
