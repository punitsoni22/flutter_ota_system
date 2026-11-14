// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Public keys (key id -> base64 uncompressed P-256 point) that may sign the official toolchain
/// index. Embedded in the CLI, so a mirror cannot change them.
///
/// `flutter-ota-toolchain-1` is the official toolchain-signing key, created by the owner with
/// `tools/toolchain/build_bundle.sh`. Its private key is kept offline by the owner and never enters
/// the repository.
///
/// Self-builders and private mirrors can trust their own key as well with
/// `flutter_ota config add-toolchain-key <key_id> <public_key_base64>`.
const Map<String, String> embeddedToolchainKeys = {
  'flutter-ota-toolchain-1': 'BIf+3nTyIc2zDfYQtoQMMFHiBNRT5Mco/+H6Q4yiI18MopOgUiJUeVuSoMrtVF+dzWjsVagbykjJioA8s9fdm6E=',
};

/// URL of the official toolchain index for this CLI version: a GitHub release asset. Each CLI
/// release pins its own index; override it with `flutter_ota config set toolchain-index-url <url>`
/// or `FLUTTER_OTA_TOOLCHAIN_INDEX` (for example a local mirror).
const String defaultToolchainIndexUrl =
    'https://github.com/punitsoni22/flutter_ota_system/releases/download/v0.3.0-alpha/toolchain-index.json';
