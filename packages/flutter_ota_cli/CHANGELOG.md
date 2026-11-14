## 0.2.0-alpha.2

Text and display fixes found in the public v0.2.0-alpha validation (no behaviour change):
* `flutter_ota init` lists the real next steps (it printed a leftover internal line).
* `flutter_ota config get/list` show the built-in default toolchain index URL, and `config list`
  names the built-in trusted toolchain key.
* `flutter_ota status` marks the channels of rolled-back or revoked patches as "(was) …" and keeps
  the columns aligned.
* `flutter_ota patch android` labels the manifest patch id and prints the promote command with
  the server patch id.

## 0.2.0-alpha.1

* Fix: `dart pub global activate flutter_ota_cli` failed to compile 0.2.0-alpha
  (`dynamicModulesPackageFiles` was defined in a file that is not published). A test now checks
  that published code never imports the owner-side toolchain builder.
* Same toolchain as 0.2.0-alpha (the `v0.2.0-alpha` GitHub release).

## 0.2.0-alpha

First release on pub.dev. **Experimental alpha. The CLI runs on Linux x64 and builds Android arm64
apps with Flutter 3.47.9 and the Flutter OTA engine.**

* `flutter_ota init`, `config`, `doctor`: connect a Flutter project to a self-hosted Flutter OTA
  System server.
* `flutter_ota toolchain install | list | doctor | clean` and `flutter_ota upgrade`:
  * download, verify and cache the pinned toolchain: the official Flutter SDK archive plus the
    signed Flutter OTA overlay;
  * the default index is a GitHub release asset of this version;
  * downloads resume after an interruption, and every file is checked against its SHA-256 in the
    ES256-signed index.
* `flutter_ota keys init`: an offline root key and a certified signer key, kept on your machine.
* `flutter_ota release android`: builds the store APK or AAB locally with the toolchain and
  registers the release.
  * It refuses a build without the OTA engine, checked by the ELF build ID.
  * It refuses a build with native libraries for ABIs other than arm64-v8a.
* `flutter_ota features`, `flutter_ota patch android`: build, check, sign and upload a feature
  patch (Dart bytecode) locally.
* `flutter_ota status`, `flutter_ota rollback`.
