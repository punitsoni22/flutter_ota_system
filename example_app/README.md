# ota_example

Example Flutter app for [Punit](../README.md). It uses `ota_client` with `MockPatchRuntime`: a
patch is a signed JSON file (`mock-v1`) that changes the app's banner and colour. No code is
downloaded.

Run it against the local stack by following [docs/installation.md](../docs/installation.md)
(step 8):

```bash
flutter run \
  --dart-define=OTA_SERVER_URL=http://10.0.2.2:8000 \
  --dart-define=OTA_APP=punit-demo \
  --dart-define=OTA_CHANNEL=dev \
  --dart-define=OTA_PUBLIC_KEY=local-dev-1:<base64 point printed by ./scripts/seed_demo.sh>
```

A patch containing `{"crash": true}` makes the app exit on start, to demonstrate crash
protection. The app allows cleartext HTTP for local testing only.
