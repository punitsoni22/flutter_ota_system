# ota_example

Example Flutter app for [Punit](../README.md). It uses `ota_client` with `MockPatchRuntime`: a
patch is a signed JSON file (`mock-v1`) that changes the app's banner and colour. No code is
downloaded.

Run it against the local stack by following [docs/installation.md](../docs/installation.md)
(step 8):

```bash
flutter run \
  --dart-define=OTA_SERVER_URL=http://10.0.2.2:8000 \
  --dart-define=OTA_PUBLIC_KEY=local-dev-1:<base64 point printed by ./punit.sh status>
```

Defaults: `OTA_APP=punit-demo` and `OTA_CHANNEL=dev`, which match `./punit.sh demo`; override
them with `--dart-define` if you use other values. For a USB phone, use
`OTA_SERVER_URL=http://localhost:8000` with `adb reverse` (see the installation guide).

A patch containing `{"crash": true}` makes the app exit on start, to demonstrate crash
protection. The app allows cleartext HTTP for local testing only.

**Platforms:** the example app has been tested internally on **Android** only, on a small number
of devices. The `ios/` folder comes from the Flutter template; the app has **not** been built or
run on iOS. See the [testing status](../README.md#platform-support--testing-status).
