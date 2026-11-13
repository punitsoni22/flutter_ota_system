# flutter_ota_cli example

The CLI is a command-line tool. A complete session in a Flutter app folder, on Linux x64:

```bash
dart pub global activate flutter_ota_cli

flutter_ota init --app-id <server app UUID>          # writes flutter_ota.yaml
flutter_ota config set server-url https://ota.example.com
export FLUTTER_OTA_ADMIN_KEY=<admin API key>

flutter_ota toolchain install                        # downloads and verifies the toolchain; writes flutter_ota.lock
flutter_ota keys init                                # offline root key + signer key, on this machine only
flutter_ota doctor

flutter_ota release android                          # store AAB (or --kind apk), built locally
# ...change code in a feature package...
flutter_ota patch android --channel staging          # build, check, sign and upload a patch
flutter_ota status
flutter_ota rollback
```

See the [quick start](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/quick-start.md).
