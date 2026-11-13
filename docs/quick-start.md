# Quick start: release and patch an Android app

This guide takes a Flutter app from zero to a working OTA patch with the bytecode architecture.

> [!WARNING]
> **Experimental alpha.**
> - Supported: Android arm64 apps, built on a Linux x64 machine.
> - The `flutter_ota_system` package and the `flutter_ota_cli` tool are **not yet on pub.dev**, and the custom toolchain is **not yet published**.
> - This guide shows the commands that work today, and the planned commands for after publication.

You need:
- Linux x64 with Git, Docker (for the server) and about 10 GB of free disk;
- an Android arm64 phone for testing;
- your app's feature code in **feature packages** (see step 6).

## 1. Install

**SDK (in your app).** Once published:

```bash
flutter pub add flutter_ota_system
```

Today, add it as a Git dependency in `pubspec.yaml`:

```yaml
dependencies:
  flutter_ota_system:
    git:
      url: https://github.com/punitsoni22/flutter_ota_system.git
      path: packages/ota_client
```

**CLI (on your machine).** Once published:

```bash
dart pub global activate flutter_ota_cli
```

Today, from a clone of this repository:

```bash
git clone https://github.com/punitsoni22/flutter_ota_system.git
dart pub global activate --source path flutter_ota_system/packages/flutter_ota_cli
```

Make sure `~/.pub-cache/bin` is on your `PATH`, then check:

```bash
flutter_ota --version
```

## 2. Run your server

Follow [self-hosting](self-hosting.md). For a local test stack:

```bash
cd flutter_ota_system
./flutter-ota-system.sh setup
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
export FLUTTER_OTA_ADMIN_KEY=<admin API key>                  # never stored in files by flutter_ota
```

`flutter_ota.yaml` contains **only** the app id:

```yaml
app_id: 7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5
```

This is the **server's application UUID**. It is not the slug, the Android application ID or the package name. Never put keys or secrets in this file.

## 4. Install the custom toolchain

The CLI downloads, verifies and caches its own Flutter SDK, together with our custom engine. You never build or configure the engine, and your global Flutter install is never used or changed.

**Today** there is no official toolchain download yet. Point the CLI at a toolchain mirror (one you built with the [owner tool](toolchain-management.md#6-building-the-toolchain-yourself), or one a teammate built) and trust its signing key:

```bash
flutter_ota config set toolchain-index-url file:///path/to/mirror/index.json
flutter_ota config add-toolchain-key <key_id> <public_key_base64>
flutter_ota toolchain install      # also writes flutter_ota.lock: commit it
flutter_ota toolchain doctor
```

## 5. Create your signing keys

```bash
flutter_ota keys init
```

This creates the following in `~/.config/flutter_ota/keys/<app_id>/`:
- an **offline root key**: back it up offline, for example on an encrypted USB stick;
- a **signer key**, certified by the root key, used by `patch android` on this machine.

Only the public keys and the certificate are sent to your server. Private keys never go into your project, your APK or your server. See [security](security.md).

## 6. Prepare the app

**`main.dart`.** Call `initialize()` once:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterOta.initialize();
  runApp(const MyApp());
}
```

**Feature packages.** Patchable code lives in local packages, for example `packages/products/`. Each one has an entry class in `lib/<package>.dart`:

```dart
// packages/products/lib/products.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

class ProductsFeature extends OtaFeature {
  @override
  Widget build(BuildContext context, [Object? arguments]) => const ProductScreen();
}
```

Your app shows the feature through the generated registry, `OtaFeatures.products.build(context)`. `flutter_ota release android` generates it. Details are in [feature patching](feature-patching.md).

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

What it does:
- builds your app with the custom toolchain, on your machine;
- generates `lib/flutter_ota_main.g.dart` (the build entry point) and `lib/flutter_ota_features.g.dart` (the feature registry) — commit both;
- adds the `dynamic_modules` loader package under `.flutter_ota/packages/` — commit it;
- registers the release with your server. **It uploads only `libapp.so` and the release metadata**, never your source code or the APK/AAB.

**Upload the AAB to Google Play yourself.** The output path is printed.

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

**Promote it to production.** After testing on staging, use the Python admin CLI:

```bash
ota patch promote <patch_id> --percent 10              # staging → production, 10% of devices
```

The server refuses production without staging first. `flutter_ota` has no promote command yet.

**What the phones do:**
- At the next app start, the phone downloads and verifies the patch.
- At the start after that, it runs it.

## 9. Watch it, and roll back if needed

```bash
flutter_ota status                  # release, patches, channels, rollout %, devices
flutter_ota rollback                # rolls back the newest published patch (asks first)
```

After a rollback, devices go back to the previous patch, or to the store code, at their next start.

## Next

- [CLI reference](cli-reference.md): every command and option.
- [Feature patching](feature-patching.md): what can and cannot be patched.
- [Troubleshooting](troubleshooting.md).
- [Demo app](../packages/ota_client/example/README.md): the products feature with freezed, a v1 → v2 patch and rollback.
