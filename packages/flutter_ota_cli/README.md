# flutter_ota_cli

`flutter_ota`, the developer command-line tool of **[Flutter OTA System](https://github.com/punitsoni22/flutter_ota_system)**,
an open-source, self-hosted OTA update platform for Flutter apps.

> [!WARNING]
> **Experimental alpha.** Linux x64 developer machines, Android arm64 apps. Not yet published on
> pub.dev. Not production-ready.

It does, on **your** machine:

- installs and verifies the Flutter OTA custom toolchain automatically (your global Flutter is
  never used or changed);
- creates your signing keys (`keys init`): an offline root key and a certified signer key;
- builds the store APK/AAB with the custom engine and registers the release (`release android`);
- finds what changed in your feature packages, compiles it to Dart bytecode, verifies it, signs it
  locally and uploads it (`patch android`);
- shows and rolls back patches (`status`, `rollback`).

No source code is uploaded and the server never holds your private signing keys.

## Install

Once published:

```bash
dart pub global activate flutter_ota_cli
```

Today, from a clone of the repository:

```bash
dart pub global activate --source path packages/flutter_ota_cli
flutter_ota --version
```

## Commands

`init`, `config`, `toolchain`, `upgrade`, `keys`, `doctor`, `release android`, `features`,
`patch android`, `status`, `rollback`. See the
[CLI reference](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/cli-reference.md)
and the [quick start](https://github.com/punitsoni22/flutter_ota_system/blob/main/docs/quick-start.md).

## Development

```bash
dart pub get && dart analyze && dart test
```

Apache License 2.0, Copyright The Punit Authors.
