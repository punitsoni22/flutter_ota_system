// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import '../toolchain/canonical_json.dart';

/// Name of the single dart-define the CLI injects (runtime contract §1).
const otaConfigDefine = 'FLUTTER_OTA_CONFIG';

/// Entry contract of patch modules built for this release (runtime contract §4).
const entryContract = 3;

/// The build-time configuration compiled into the app (runtime contract §1). Never contains a
/// private key, an admin key or any other secret.
Map<String, Object?> buildOtaConfig({
  required String appId,
  required String serverUrl,
  required String releaseId,
  required String environment,
  required Map<String, String> rootKeys,
  required String toolchainId,
  required Map<String, String> runtime,
  required String interfaceSha256,
  required List<String> hostPackages,
  String? releaseVersion,
  String? channel,
}) => {
  'format': 1,
  'app_id': appId,
  'server_url': serverUrl,
  'release_id': releaseId,
  'environment': environment,
  'root_keys': rootKeys,
  'toolchain_id': toolchainId,
  'runtime': runtime,
  'interface_sha256': interfaceSha256,
  'host_packages': hostPackages,
  'entry_contract': entryContract,
  // Optional fields (SDK runtime doc): the update check sends release_version as the backend
  // release version; channel defaults to production in the SDK.
  'release_version': ?releaseVersion,
  'channel': ?channel,
};

/// `base64url(canonical JSON)`, with `=` padding (Dart's `base64Url.decode` needs it). The value
/// contains no commas, which both `flutter --dart-define` and the front end's `-D` would split on.
String encodeOtaConfig(Map<String, Object?> config) => base64Url.encode(canonicalJson(config));

/// Inverse of [encodeOtaConfig] (accepts missing padding).
Map<String, Object?> decodeOtaConfig(String value) =>
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(value)))) as Map<String, Object?>;
