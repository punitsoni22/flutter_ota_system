// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Public keys (key id -> base64 uncompressed P-256 point) that may sign the official toolchain
/// index. Embedded in the CLI, so a mirror cannot change them.
///
/// EMPTY ON PURPOSE: no official toolchain has been published yet (publishing needs a separate
/// owner approval). When the owner creates the official toolchain-signing key with
/// `tools/toolchain/build_bundle.sh`, its public key (printed by the tool) is added here in a
/// reviewed commit. The private key never enters the repository.
///
/// Until then, self-builders and local mirrors trust their own key with
/// `flutter_ota config add-toolchain-key <key_id> <public_key_base64>`.
const Map<String, String> embeddedToolchainKeys = {};

/// URL of the official toolchain index for this CLI version: a GitHub release asset. Each CLI
/// release pins its own index; override it with `flutter_ota config set toolchain-index-url <url>`
/// or `FLUTTER_OTA_TOOLCHAIN_INDEX` (for example a local mirror).
const String defaultToolchainIndexUrl =
    'https://github.com/punitsoni22/flutter_ota_system/releases/download/v0.2.0-alpha/toolchain-index.json';
