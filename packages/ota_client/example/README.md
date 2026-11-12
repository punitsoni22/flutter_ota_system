# Flutter OTA System demo app

The official demo app of [Flutter OTA System](../../../README.md) and the `flutter_ota_system`
package. It is the **only** demo app in the repository.

It shows the whole client flow in one small screen ([`lib/main.dart`](lib/main.dart)):
initialising the client, registering the installation, checking for a patch, verifying it
(ES256 signature, size, SHA-256), activating it on the next start, confirming a good start,
falling back after a broken patch, and showing errors.

It uses `MockPatchRuntime`: a patch is a signed JSON file (`mock-v1`) that changes the app's
banner and colour. **No code is downloaded.** Android Dart code patches (`AotPatchRuntime`) are
experimental; see [docs/releases-and-patches.md](../../../docs/releases-and-patches.md).

## Run it against the local server

You need Linux, Docker and Flutter `>=3.44.9`. The full walkthrough is in
[docs/installation.md](../../../docs/installation.md) (step 8).

1. From the repository root, start the local stack and publish a test patch:

   ```bash
   ./flutter-ota-system.sh setup
   ./flutter-ota-system.sh demo
   ./flutter-ota-system.sh status    # prints OTA_APPLICATION_ID and OTA_PUBLIC_KEY
   ```

2. Run the demo app on an Android emulator:

   ```bash
   cd packages/ota_client/example
   flutter run \
     --dart-define=OTA_SERVER_URL=http://10.0.2.2:8000 \
     --dart-define=OTA_APPLICATION_ID=<OTA_APPLICATION_ID printed by status> \
     --dart-define=OTA_PUBLIC_KEY=local-dev-1:<base64 point printed by status>
   ```

   For a USB phone, run `adb reverse tcp:8000 tcp:8000` and `adb reverse tcp:8080 tcp:8080`
   first, and use `OTA_SERVER_URL=http://localhost:8000`.

3. Tap **Check for update now**, close the app fully and open it again: the patch's banner and
   colour appear.

Defaults: `OTA_APP=flutter-ota-system-demo` and `OTA_CHANNEL=dev`, which match
`./flutter-ota-system.sh demo`. Override them with `--dart-define` if you use other values.

**Try rollback and crash protection:** a patch containing `{"crash": true}` makes the app exit on
start, like a broken patch would. The next start comes back on the last good code. Rolling back or
revoking a patch on the server also brings the app back after a restart. Commands:
[docs/installation.md](../../../docs/installation.md) and [docs/rollouts.md](../../../docs/rollouts.md).

## Use it with your own server

Pass your own values with `--dart-define`: `OTA_SERVER_URL` (must be `https://` in release
builds), `OTA_APP` (the app slug), `OTA_CHANNEL`, `OTA_APPLICATION_ID` (`"id"` in
`ota app list`) and `OTA_PUBLIC_KEY` (`<key id>:<base64 point>` from `ota key show`). The
build's version and build number (`pubspec.yaml`) must match a release registered on the server.

## Notes

- **Platforms:** tested internally on **Android** only, on a small number of devices. There is no
  iOS project; iOS is not supported.
- The app allows cleartext HTTP so it can reach the local `http://` server. The SDK itself refuses
  `http://` URLs in release builds.
- The Android application ID is `dev.flutterota.ota_example`. Use your own application ID in your
  apps.
- The `android/` folder is a Flutter template project kept in Git so `flutter run` works without
  extra steps. It is not part of the published package.
