// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'canonical_json.dart';

/// Name of the overlay manifest inside the overlay archive and in an installed toolchain.
const overlayManifestName = 'overlay.json';

/// Name of the install record written last into an installed toolchain.
const installRecordName = 'install.json';

/// Files of the stock SDK whose hashes are recorded at install time (relative to `flutter/`).
const recordedSdkFiles = ['bin/flutter', 'bin/internal/engine.version', 'bin/cache/dart-sdk/bin/dart'];

/// Relative path of the Android arm64 release gen_snapshot inside a Flutter SDK.
const genSnapshotSdkPath = 'bin/cache/artifacts/engine/android-arm64-release/linux-x64/gen_snapshot';

/// The tool snapshots every toolchain ships (run with the SDK's `dartaotruntime`).
const toolSnapshots = ['dart2bytecode', 'pkg_rename', 'patch_guard'];

/// Recomputes the content-hash id of a `toolchain.json` record: SHA-256 of the canonical JSON of
/// every field except `id` (same rule as prototypes/security_hardening/tools/toolchain.py).
String computeToolchainId(Map<String, Object?> record) {
  final fields = Map<String, Object?>.of(record)..remove('id');
  return sha256.convert(canonicalJson(fields)).toString();
}

/// Maven artifacts the local mirror must contain for an Android arm64 release build.
List<String> mirrorFilesFor(String engineCommit) {
  final v = '1.0.0-$engineCommit';
  const base = 'mirror/download.flutter.io/io/flutter';
  return [
    for (final a in ['arm64_v8a_release', 'flutter_embedding_release'])
      for (final ext in ['jar', 'pom']) '$base/$a/$v/$a-$v.$ext',
  ];
}

/// Parsed `overlay.json`.
class OverlayManifest {
  OverlayManifest(this.json);

  factory OverlayManifest.read(String path) {
    final j = jsonDecode(File(path).readAsStringSync());
    if (j is! Map<String, Object?> || j['format'] != 1) throw const FormatException('unsupported overlay manifest');
    return OverlayManifest(j);
  }

  final Map<String, Object?> json;

  String get toolchain => json['toolchain'] as String;
  String get toolchainId => json['toolchain_id'] as String;
  String get engine => json['engine'] as String;

  /// overlay-relative path -> sha256
  Map<String, String> get files => {
    for (final e in (json['files'] as Map<String, Object?>).entries)
      e.key: (e.value as Map<String, Object?>)['sha256'] as String,
  };

  /// SDK-relative path -> sha256 of the stock file it replaces.
  Map<String, String> get sdkReplacements => {
    for (final e in (json['sdk_replacements'] as Map<String, Object?>).entries)
      e.key: (e.value as Map<String, Object?>)['stock_sha256'] as String,
  };
}

/// Where an overlay file ends up inside an installed toolchain: `sdk/X` goes into `flutter/X`,
/// everything else keeps its path.
String installedPathOf(String overlayPath) =>
    overlayPath.startsWith('sdk/') ? 'flutter/${overlayPath.substring(4)}' : overlayPath;

/// Rejects absolute paths and `..` segments in archive-controlled names.
bool isSafeRelative(String rel) =>
    rel.isNotEmpty && !p.isAbsolute(rel) && !p.split(rel).contains('..') && !rel.contains('\\');
