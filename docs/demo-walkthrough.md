<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Demo walkthrough: patch a feature on a phone

This guide shows the whole Flutter OTA System flow with the demo app in
[`packages/ota_client/example`](../packages/ota_client/example). You change real Dart code in a
feature (API endpoint, freezed model, entity, repository and UI), send it as a patch, and the
phone runs the new code after a restart. **No reinstall. The store build's `libapp.so` does not
change.**

> **Experimental alpha.** Tested only on a Linux x64 computer with one Android arm64 phone
> connected by USB. Not for production use. Other platforms are not supported.

## Status of this guide (Phase 4)

Some commands in this guide are still being built. They are marked like this: **(4E)**.

| Milestone | What it adds | Used in |
| --- | --- | --- |
| 4C | `FlutterOta.initialize()`, `FlutterOta.feature()`, `OtaFeature` and the status getters in the SDK | the demo app itself (it does not compile without them) |
| 4D | `flutter_ota doctor`, `flutter_ota keys init`, `flutter_ota release android` | Part A, Part B |
| 4E | `flutter_ota patch android` | step 7 |
| 4F | `flutter_ota features generate` (writes `lib/flutter_ota_features.g.dart`) | Part A |
| 4H | `flutter_ota status`, `flutter_ota rollback` | step 9, Part D |

Exact option names of the commands marked 4E and 4H may still change. Check `flutter_ota <command> --help`.

**Open point (4C):** this guide uses the local OTA server at `http://localhost:8000` (through
`adb reverse`) inside a release build. Whether the SDK allows `http://localhost` in a release
build is decided in milestone 4C. If it does not, use an `https://` server URL instead.

## How the demo app is built

```text
packages/ota_client/example/
├─ lib/main.dart                      starts OTA, shows the products feature and an OTA status line
├─ lib/flutter_ota_features.g.dart    generated registry: the app reaches features only through it
├─ packages/core/                     shared, host-owned code (config, theme). Never patched
├─ packages/products/                 the feature package. This is what a patch replaces
│  ├─ lib/products.dart               ProductsFeature extends OtaFeature (the entry class)
│  ├─ lib/src/data/                   product_api.dart, product_model.dart (+ generated freezed/JSON files)
│  ├─ lib/src/domain/                 product_entity.dart, product_repository.dart
│  └─ lib/src/presentation/           product_screen.dart, product_controller.dart
├─ demo_api/                          the demo's own product API: v1/ and v2/products.json, serve.sh
└─ demo_patch_v2/products/            the "after" files for steps 1-5 (copy them over packages/products)
```

Why a separate package? A patch can only **add** new code; it cannot replace code the app already
loaded. So every patchable feature lives in its own package, and the app calls it only through a
type the store build owns (`OtaFeature`). See
[phase-4-runtime-contract.md](architecture/phase-4-runtime-contract.md), section 3.

The product list comes from a tiny local web server on your computer
(`http://127.0.0.1:8090`). The phone reaches it through `adb reverse`. The app allows plain
`http://` only to `127.0.0.1` and `localhost`
([network_security_config.xml](../packages/ota_client/example/android/app/src/main/res/xml/network_security_config.xml)).

## Part A: one-time setup

Run every command from the repository root unless a step says otherwise.

1. Start the local OTA server and install the Python admin tool:

   ```bash
   ./flutter-ota-system.sh setup
   ./flutter-ota-system.sh cli
   ```

2. Create the app on the server and copy its `id` (a UUID):

   ```bash
   unset OTA_API_URL
   ./flutter-ota-system.sh ota app create ota-demo "OTA demo"
   ./flutter-ota-system.sh ota app list
   ```

3. Install the developer tool `flutter_ota`:

   ```bash
   dart pub global activate --source path packages/flutter_ota_cli
   export PATH="$PATH:$HOME/.pub-cache/bin"
   flutter_ota --version
   ```

4. Point it at the local server and give it the admin key for this shell only. For the local
   stack, the key is `OTA_ADMIN_API_KEY` in `.env`:

   ```bash
   flutter_ota config set server-url http://localhost:8000
   read -rs FLUTTER_OTA_ADMIN_KEY && export FLUTTER_OTA_ADMIN_KEY
   ```

5. Set up the demo app folder:

   ```bash
   cd packages/ota_client/example
   flutter_ota init --app-id <the id from step 2>
   flutter_ota toolchain install
   flutter_ota keys init                    # (4D) your signing keys, kept on this computer
   flutter_ota features generate            # (4F) rewrites lib/flutter_ota_features.g.dart
   flutter_ota doctor                       # (4D) every line should say OK
   ```

   `flutter_ota keys init` keeps the private keys on your computer. Never commit them.

## Part B: build and install the store version

1. In a **second terminal**, start the product API and connect the phone to it:

   ```bash
   cd packages/ota_client/example
   ./demo_api/serve.sh
   ```

   In the first terminal:

   ```bash
   adb reverse tcp:8090 tcp:8090     # product API
   adb reverse tcp:8000 tcp:8000     # local OTA server
   ```

   Run `adb reverse` again every time you reconnect the phone.

2. Build the store version with the OTA toolchain and install it **once**:

   ```bash
   flutter_ota release android --kind apk   # (4D) builds, and registers the release on the server
   adb install build/app/outputs/flutter-apk/app-release.apk
   ```

3. Open the app. You see **"Products (v1)"** with three products and their prices. The bottom
   line says `OTA: on | active patch: none (store code)`.

4. Write down the fingerprint of the store code, so you can check later that it did not change:

   ```bash
   adb pull "$(adb shell pm path dev.flutterota.ota_example | head -1 | sed 's/^package://' | tr -d '\r')" store.apk
   unzip -p store.apk lib/arm64-v8a/libapp.so | sha256sum
   adb shell dumpsys package dev.flutterota.ota_example | grep lastUpdateTime
   ```

## Part C: the 9 steps

Steps 1-5 change code in `packages/products`. Each "after" file is ready in
`demo_patch_v2/products/`. You can make the changes by hand (compare the files), or copy them all
at once:

```bash
cp -r demo_patch_v2/products/. packages/products/
```

1. **Change the API endpoint.** In `packages/products/lib/src/data/product_api.dart`:
   `'/v1/products.json'` becomes `'/v2/products.json'`. The v2 data has a new field, `rating`.
   `serve.sh` serves both versions at the same time, so the old app keeps working.

2. **Add the field to the model.** In `packages/products/lib/src/data/product_model.dart`, add
   `double? rating,` to the `ProductModel` factory.

3. **Regenerate the freezed and JSON code:**

   ```bash
   cd packages/products
   flutter pub get
   dart run build_runner build --delete-conflicting-outputs
   cd ../..
   ```

   Always do this after changing a model. Old generated files would read the wrong JSON.

4. **Change the entity and the repository.** `product_entity.dart` gets a `rating` field;
   `product_repository.dart` copies `m.rating` into the entity.

5. **Change the UI.** `product_screen.dart` shows a star and the rating on each row, and the title
   becomes "Products (v2, with rating)".

6. **Check the code** (optional but quick):

   ```bash
   flutter analyze
   ```

7. **Create and upload the patch** **(4E)**:

   ```bash
   flutter_ota patch android
   ```

   It finds the changed feature, checks it (no FFI, no dynamic calls), compiles it to bytecode,
   verifies it, signs it on your computer and uploads it. No new APK is built.

8. **The app gets the patch.** Open the app (or keep it open). It checks for updates in the
   background, then downloads and verifies the patch. Nothing changes on screen yet.

9. **Restart the app and see the new functionality.** Close it fully, then open it again:

   ```bash
   adb shell am force-stop dev.flutterota.ota_example
   adb shell monkey -p dev.flutterota.ota_example 1
   ```

   You now see **"Products (v2, with rating)"** with a star and rating on each product. The bottom
   line shows the active patch. Check it on the server too **(4H)**:

   ```bash
   flutter_ota status
   ```

   **Proof that nothing was reinstalled:** run the commands from Part B step 4 again (save to
   `after.apk` instead of `store.apk`). The `libapp.so` SHA-256 and `lastUpdateTime` are the same
   as before.

## Part D: rollback

Take the patch back on the server **(4H)**:

```bash
flutter_ota rollback
```

Then restart the app (Part C, step 9 commands; you may need to open it twice: once to learn about
the rollback, once to start on the old code). You see "Products (v1)" again, with no rating.

The app also falls back by itself: if a new patch does not start correctly, the next start uses
the last good code. That is the crash protection from Phase 3C.

To put the demo source back to v1 on your computer:

```bash
git checkout -- packages/products
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "Could not load products" | Is `./demo_api/serve.sh` running? Run `adb reverse tcp:8090 tcp:8090` again |
| Bottom line says `OTA: off` | The app was built with plain `flutter run`/`flutter build`. Use `flutter_ota release android` |
| `flutter_ota patch android` refuses the patch | Read the message; it names the file and line. Common causes: generated files not up to date (run step 3), a dynamic call |
| The patch never arrives | Is `adb reverse tcp:8000 tcp:8000` active? `flutter_ota status` shows whether the server has it |

## Known limits

- Only code inside feature packages (`packages/products`) can be patched. `lib/main.dart` and
  `packages/core` cannot.
- A patch cannot change the store build's native code, Android settings or plugin list.
- Tested on Android arm64 only.
