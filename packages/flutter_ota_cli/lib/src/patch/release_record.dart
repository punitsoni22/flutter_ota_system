// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import 'manifest.dart';

/// The local baseline of a store release (`.flutter_ota/releases/<release_id>/`), written by
/// `flutter_ota release android` (4D). The patch pipeline reads:
///
///   release.json            app_id, release_id, environment, libapp_sha256, toolchain_id,
///                           toolchain_record, runtime, interface_sha256, root_keys,
///                           entry_contract, canonical_build_root, registered, created_at
///   link.dill               kernel of the store build (patches are compiled against it)
///   dynamic_interface.yaml  what patches may use (its SHA-256 is interface_sha256)
///   host_packages.json      {"internal": [...], "all": [...]} packages of the store build
///   pubspec.lock            the store build's resolution
///   feature_snapshot.json   source hashes at release time (written by recordFeatureSnapshot)
class ReleaseRecord {
  ReleaseRecord._(this.dir, this.json);

  static String releasesDir(String projectDir) => p.join(projectDir, '.flutter_ota', 'releases');

  /// Loads the release [releaseId], or the newest release when null.
  static ReleaseRecord find(String projectDir, {String? releaseId}) {
    final root = Directory(releasesDir(projectDir));
    if (releaseId != null) {
      if (!isUuid(releaseId)) throw CliException('"$releaseId" is not a release id (UUID).');
      final d = p.join(root.path, releaseId);
      if (!Directory(d).existsSync()) {
        throw CliException(
          'There is no local release $releaseId in ${root.path}. Patches need the files the '
          'release command keeps there (link.dill, interface, snapshot).',
        );
      }
      return load(d);
    }
    final all = <ReleaseRecord>[];
    if (root.existsSync()) {
      for (final d in root.listSync().whereType<Directory>()) {
        if (p.basename(d.path).startsWith('.')) continue;
        if (!File(p.join(d.path, 'release.json')).existsSync()) continue;
        all.add(load(d.path));
      }
    }
    if (all.isEmpty) {
      throw CliException('No store release found in ${root.path}. Build one first:  flutter_ota release android');
    }
    all.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all.last;
  }

  /// Loads and checks one release directory.
  static ReleaseRecord load(String dir) {
    final f = File(p.join(dir, 'release.json'));
    final Object? j;
    try {
      j = jsonDecode(f.readAsStringSync());
    } on Object {
      throw CliException('${f.path} is missing or not valid JSON.');
    }
    if (j is! Map<String, Object?> || j['format'] != 1) {
      throw CliException('${f.path} is not a supported release record.');
    }
    final r = ReleaseRecord._(dir, j);
    r._check();
    return r;
  }

  final String dir;
  final Map<String, Object?> json;

  String _str(String k) {
    final v = json[k];
    if (v is! String || v.isEmpty) throw CliException('release.json in $dir has no "$k".');
    return v;
  }

  String get appId => _str('app_id');
  String get releaseId => _str('release_id');
  String get environment => _str('environment');
  String get libappSha256 => _str('libapp_sha256');
  String get interfaceSha256 => _str('interface_sha256');
  String get toolchainId => _str('toolchain_id');

  /// Name of the toolchain the release was built with (for example `flutter-3.47.9-ota.1`).
  String get toolchainName => _str('toolchain');
  String get createdAt => (json['created_at'] as String?) ?? '';
  String? get canonicalBuildRoot => json['canonical_build_root'] as String?;
  String? get serverUrl => json['server_url'] as String?;
  String? get version => json['version'] as String?;

  Map<String, Object?> get toolchainRecord => ((json['toolchain_record'] as Map?) ?? const {}).cast<String, Object?>();

  /// The manifest's toolchain object: the 9 recorded fields and their id.
  Map<String, Object?> get manifestToolchain => {
    for (final k in toolchainRecordFields) k: toolchainRecord[k],
    'id': toolchainId,
  };

  Map<String, String> get runtime => ((json['runtime'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));
  Map<String, String> get rootKeys => ((json['root_keys'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));

  /// `registered` block, null when the release was never registered on a server.
  Map<String, Object?>? get registered => (json['registered'] as Map?)?.cast<String, Object?>();

  String get linkDill => p.join(dir, 'link.dill');
  String get dynamicInterface => p.join(dir, 'dynamic_interface.yaml');
  String get hostPackagesJson => p.join(dir, 'host_packages.json');
  String get pubspecLock => p.join(dir, 'pubspec.lock');
  String get patchesDir => p.join(dir, 'patches');

  /// Every package of the store build (`host_packages.json` "all").
  Set<String> get hostPackages {
    final j = jsonDecode(File(hostPackagesJson).readAsStringSync());
    final all = j is Map ? j['all'] : null;
    if (all is! List) throw CliException('$hostPackagesJson has no "all" list.');
    return all.cast<String>().toSet();
  }

  void _check() {
    final id = releaseId;
    if (!isUuid(id) || !isUuid(appId)) throw CliException('release.json in $dir has an invalid app_id or release_id.');
    if (p.basename(dir) != id) throw CliException('The release directory $dir does not match its release_id $id.');
    for (final f in [linkDill, dynamicInterface, hostPackagesJson]) {
      if (!File(f).existsSync()) throw CliException('The release in $dir is incomplete: ${p.basename(f)} is missing.');
    }
    final iface = sha256.convert(File(dynamicInterface).readAsBytesSync()).toString();
    if (iface != interfaceSha256) {
      throw CliException(
        'dynamic_interface.yaml in $dir was changed after the release (SHA-256 differs). '
        'Patches must be built against the exact interface of the store build.',
      );
    }
    final linkSha = json['link_dill_sha256'];
    if (linkSha is String && sha256.convert(File(linkDill).readAsBytesSync()).toString() != linkSha) {
      throw CliException('link.dill in $dir was changed after the release (SHA-256 differs).');
    }
    if (toolchainRecordId(toolchainRecord) != toolchainId) {
      throw CliException('release.json in $dir: the toolchain record does not match toolchain_id.');
    }
    final ec = json['entry_contract'];
    if (ec != null && ec != entryContract) {
      throw CliException(
        'The release in $dir uses entry contract $ec; this CLI builds contract $entryContract patches.',
      );
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(libappSha256)) {
      throw CliException('release.json in $dir has no valid libapp_sha256.');
    }
    for (final k in ['flutter', 'dart', 'engine', 'abi', 'runtime_id']) {
      if (!runtime.containsKey(k)) throw CliException('release.json in $dir: runtime.$k is missing.');
    }
  }

  /// Highest patch sequence built locally for this release (0 when none).
  int localHighestSequence() {
    final d = Directory(patchesDir);
    if (!d.existsSync()) return 0;
    var max = 0;
    for (final s in d.listSync().whereType<Directory>()) {
      final n = int.tryParse(p.basename(s.path));
      if (n != null && n > max && File(p.join(s.path, 'patch.otp')).existsSync()) max = n;
    }
    return max;
  }
}
