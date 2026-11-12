# flutter_ota_system example

A minimal app that boots the Flutter OTA System client and checks for updates on a button press.

1. Replace the placeholders in `lib/main.dart` with your server URL, app slug, application id
   (`ota app list`), release version and public key (`ota key show --dart`).
2. Generate the Android project and run it:

   ```bash
   flutter create --platforms=android .
   flutter run
   ```

Android is the only tested platform. Release builds require an `https://` server.
