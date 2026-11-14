# Quick start: release and patch an Android app

This guide takes a Flutter app from zero to a working OTA patch with the bytecode architecture.

> [!WARNING]
> **Experimental alpha.**
> - Release `v0.3.0-alpha`: Android **arm64** apps, built on a **Linux x64** machine with Flutter **3.47.9 or 3.50.0** and our custom engine.
> - Not production-ready, no independent security audit, no app-store approval of any kind.

You need:
- Linux x64 with Git, Docker (for the server) and about 10 GB of free disk;
- **Flutter 3.47.9 or 3.50.0** for `flutter pub` and your IDE: the same version as the toolchain your project pins (step 4). After the first release your project depends on the toolchain's `dynamic_modules` package, which needs the Dart version of your toolchain (3.13 or 3.14), so an older Flutter can no longer run `flutter pub get` in it. Ways to get that version next to your usual Flutter:
  - [fvm](https://fvm.app): `fvm use 3.47.9` (or `3.50.0`) in the project;
  - or after step 4, use the toolchain's own copy: `~/.cache/flutter_ota/toolchains/<toolchain id>/flutter/bin/flutter` (point your IDE's Flutter SDK path at `…/flutter`).

  No other versions were tested. The OTA builds always use the toolchain's own Flutter;
- an Android arm64 phone for testing;
- your app's feature code in **feature packages** (see step 6).

## 1. Install

**SDK.** In your Flutter project folder:

```bash
flutter pub add flutter_ota_system
```

**CLI (on your machine):**

```bash
dart pub global activate flutter_ota_cli
```

Make sure `~/.pub-cache/bin` (or `$PUB_CACHE/bin` if you set `PUB_CACHE`) is on your `PATH`, then check:

```bash
export PATH="$PATH:$HOME/.pub-cache/bin"     # add this line to ~/.bashrc to keep it
flutter_ota --help
```

## 2. Run your server

Follow [self-hosting](self-hosting.md). For a local test stack, in a separate folder:

```bash
git clone https://github.com/punitsoni22/flutter_ota_system.git
cd flutter_ota_system
./flutter-ota-system.sh setup
export OTA_ADMIN_API_KEY=$(grep '^OTA_ADMIN_API_KEY=' .env | cut -d= -f2-)   # the admin key setup created
```

**Create your app on the server.** Note its `id`, a UUID:

```bash
curl -s -X POST http://localhost:8000/v1/admin/apps \
  -H "X-API-Key: $OTA_ADMIN_API_KEY" -H "Content-Type: application/json" \
  -d '{"slug":"my-app","name":"My App","distribution":"public_store"}'
```

The Python admin CLI can do the same: `ota app create my-app "My App"` (see the [CLI reference](cli-reference.md#admin-cli-ota)).

## 3. Connect your project

Run these in your Flutter project folder.

```bash
flutter_ota init --app-id <server app UUID>
flutter_ota config set server-url https://ota.example.com    # or http://127.0.0.1:8000 for a local test
export FLUTTER_OTA_ADMIN_KEY=<admin API key>                  # OTA_ADMIN_API_KEY from step 2; never stored in files
```

`flutter_ota.yaml` contains **only** the app id:

```yaml
app_id: 7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5
```

This is the **server's application UUID**. It is not the slug, the Android application ID or the package name. Never put keys or secrets in this file.

## 4. Install the custom toolchain

The CLI downloads, verifies and caches its own Flutter SDK, together with our custom engine. You never build or configure the engine, and your global Flutter install is never used or changed.

```bash
flutter_ota toolchain install      # also writes flutter_ota.lock: commit it
flutter_ota toolchain doctor
```

What `install` does:
- reads the toolchain index of this CLI version (a GitHub release asset), and checks its ES256 signature against the key built into the CLI;
- in a project without `flutter_ota.lock`, picks the newest toolchain the project can build with ([toolchain management](toolchain-management.md#21-where-it-comes-from));
- downloads the official Flutter SDK archive from Google (3.47.9 or 3.50.0; about 1.5 GB) and our overlay (about 54 MB) from the GitHub release, and checks the size and SHA-256 of both;
- resumes an interrupted download when you run it again.

The first `release android` also downloads about 2 GB of Android build tools into the toolchain cache. To use your own mirror instead, see [toolchain management](toolchain-management.md).

## 5. Create your signing keys

```bash
flutter_ota keys init
```

This creates the following in `~/.config/flutter_ota/keys/<app_id>/`:
- an **offline root key**: back it up offline, for example on an encrypted USB stick;
- a **signer key**, certified by the root key, used by `patch android` on this machine.

Only the public keys and the certificate are sent to your server. Private keys never go into your project, your APK or your server. See [security](security.md).

## 6. Prepare the app

**Feature packages.** Patchable code lives in local packages, for example `packages/products/`. Create one and connect it to the app:

```bash
flutter create --template=package packages/products
(cd packages/products && flutter pub add flutter_ota_system)
flutter pub add 'products:{"path":"packages/products"}'
```

Each feature package has one entry class in `lib/<package>.dart`:

```dart
// packages/products/lib/products.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

class ProductsFeature extends OtaFeature {
  @override
  Widget build(BuildContext context, [Object? arguments]) =>
      const ProductsScreen(); // your own widget, in this package
}
```

**Generate the feature registry** (`lib/flutter_ota_features.g.dart`, one typed slot per feature; `release android` regenerates it):

```bash
flutter_ota features generate
```

**`main.dart`.** Call `initialize()` once, and show features through the registry:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

import 'flutter_ota_features.g.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterOta.initialize();
  runApp(MaterialApp(home: Builder(builder: (context) => OtaFeatures.products.build(context))));
}
```

Details are in [feature patching](feature-patching.md).

**arm64 only.** The OTA engine exists for arm64-v8a only. Keep only that ABI in `android/app/build.gradle.kts`, inside `android { defaultConfig { ... } }`:

```kotlin
ndk {
    abiFilters.clear()
    abiFilters += "arm64-v8a"
}
```

Without it, plugins that ship libraries for other ABIs (x86_64, armeabi-v7a) make Google Play offer the app to devices where it cannot start. `flutter_ota release android` refuses such a build.

**Check everything:**

```bash
flutter_ota doctor
```

Fix every `[x]` line. `doctor` only reads; it never changes anything.

## 7. Make the store release

```bash
flutter_ota release android                 # AAB by default; --kind apk for a test install
```

Each store version (`versionName+versionCode`) is one release. To make an APK as well as an AAB, give it its own build number (`--kind apk --build-number <n>`). Patches target the newest local release unless you pass `--release <id>`.

What it does:
- builds your app with the custom toolchain, on your machine;
- generates `lib/flutter_ota_main.g.dart` (the build entry point) and `lib/flutter_ota_features.g.dart` (the feature registry) — commit both;
- adds the `dynamic_modules` loader package under `.flutter_ota/packages/` — commit it;
- adds the `dynamic_modules` dependency to `pubspec.yaml` (and updates `pubspec.lock`);
- registers the release with your server. **It uploads only `libapp.so` and the release metadata**, never your source code or the APK/AAB.

**Upload the AAB to Google Play yourself.** The output path is printed. Sign it with your own upload key first: a new `flutter create` app signs release builds with the debug key, which Google Play rejects (see Flutter's [Android deployment guide](https://docs.flutter.dev/deployment/android#sign-the-app)).

**What to commit or ignore:**
- Add `/.flutter_ota/releases/` to `.gitignore`. It holds large build files. Back it up (for example as a CI artifact), because patches for this release are built against it.
- Do **not** ignore all of `.flutter_ota/`.

Your `main.dart` is never changed.

## 8. Ship a patch

**Change code** inside a feature package: API logic, models, entities, repositories, controllers or UI. If the package uses freezed or json_serializable, regenerate first:

```bash
dart run build_runner build --delete-conflicting-outputs
```

**Then build, sign and upload the patch:**

```bash
flutter_ota patch android --channel staging           # --dry-run builds and signs, but uploads nothing
```

The command:
1. detects what changed since the store release;
2. checks that the generated code is up to date;
3. compiles to bytecode and runs the security checks;
4. signs the patch with your local key;
5. uploads it.

It refuses with a clear reason if a change needs a new store release.

**Promote it to production.** After testing on staging, use the Python admin CLI from your server folder. Use the **server patch id**: `patch android` prints it (`uploaded as server patch <id>`), and so does `flutter_ota status`:

```bash
cd flutter_ota_system
./flutter-ota-system.sh cli                                         # once: installs the ota tool
./flutter-ota-system.sh ota patch promote <patch_id> --percent 10   # staging → production, 10% of devices
```

The server refuses production without staging first. `flutter_ota` has no promote command. For a server that is not the local stack, see the [CLI reference](cli-reference.md#admin-cli-ota).

**What the phones do:**
- At the next app start, the phone downloads and verifies the patch.
- At the start after that, it runs it.

## 9. Watch it, and roll back if needed

```bash
flutter_ota status                  # release, patches, channels, rollout %, devices
flutter_ota rollback                # rolls back the newest published patch (asks first)
```

After a rollback, devices go back to the patch they ran before (if they still have it), or to the store code, at their next start. They never download an older patch again (replay protection), so ship the fix as a new patch.

## Next

- [CLI reference](cli-reference.md): every command and option.
- [Feature patching](feature-patching.md): what can and cannot be patched.
- [Troubleshooting](troubleshooting.md).
- [Demo app](../packages/ota_client/example/README.md): the products feature with freezed, a v1 → v2 patch and rollback.
