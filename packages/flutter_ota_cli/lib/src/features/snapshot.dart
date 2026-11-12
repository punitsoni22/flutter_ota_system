// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Feature snapshot: what the sources looked like when a store release was built.
//
// The release command (4D) calls [recordFeatureSnapshot] right after the store build; it writes
// `<release dir>/feature_snapshot.json`. `flutter_ota patch android` compares the project with
// that snapshot to find what changed since the release. Patches are cumulative: every patch
// carries every change since the store release, never only the change since the last patch.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../toolchain/canonical_json.dart';
import 'discovery.dart';
import 'package_graph.dart';

const featureSnapshotFileName = 'feature_snapshot.json';
const featureSnapshotFormat = 1;

/// Directories never hashed (build outputs, tool state, version control, IDE files).
const _ignoredDirs = {
  '.dart_tool',
  'build',
  '.git',
  '.idea',
  '.gradle',
  '.cxx',
  'Pods',
  'ephemeral',
  '.symlinks',
  '.flutter_ota',
  'test',
  'integration_test',
};

/// Files outside lib/ that do not affect the app (documentation, IDE, lints).
bool _ignoredFile(String rel) {
  final base = p.basename(rel);
  return base.endsWith('.md') ||
      base.endsWith('.iml') ||
      base == 'pubspec.lock' ||
      base == 'pubspec.yaml' ||
      base == 'analysis_options.yaml' ||
      base == 'LICENSE' ||
      base == '.gitignore' ||
      base == '.metadata' ||
      base.startsWith('.flutter-plugins');
}

String sha256OfBytes(List<int> b) => sha256.convert(b).toString();

/// sha256 per file below [dir] (relative paths with `/`), skipping ignored directories.
Map<String, String> hashTree(String dir, {bool Function(String rel)? include}) {
  final out = <String, String>{};
  final root = Directory(dir);
  if (!root.existsSync()) return out;
  void walk(Directory d) {
    final entries = d.listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (_ignoredDirs.contains(name)) continue;
        walk(e);
      } else if (e is File) {
        final rel = p.split(p.relative(e.path, from: dir)).join('/');
        if (include != null && !include(rel)) continue;
        out[rel] = sha256OfBytes(e.readAsBytesSync());
      }
    }
  }

  walk(root);
  return out;
}

String _hashOfMap(Map<String, String> m) => sha256OfBytes(canonicalJson(m));

/// The snapshot of one package.
Map<String, Object?> _packageSnapshot(LocalPackage pkg, {required bool isApp}) {
  final lib = hashTree(pkg.libDir);
  final files = {
    for (final e in lib.entries) 'lib/${e.key}': e.value,
    if (File(p.join(pkg.dir, 'build.yaml')).existsSync())
      'build.yaml': sha256OfBytes(File(p.join(pkg.dir, 'build.yaml')).readAsBytesSync()),
  };
  final native = <String, String>{};
  for (final d in nativeDirNames) {
    hashTree(p.join(pkg.dir, d)).forEach((k, v) => native['$d/$k'] = v);
  }
  // Other files (assets, fonts, ...). For the app, nested packages are excluded: they are
  // separate packages with their own snapshot.
  final other = hashTree(
    pkg.dir,
    include: (rel) {
      final first = rel.split('/').first;
      if (first == 'lib' || nativeDirNames.contains(first) || rel == 'build.yaml' || _ignoredFile(rel)) return false;
      if (isApp && (first == 'packages' || first == 'features' || first == 'modules')) return false;
      return true;
    },
  );
  return {
    'dir': p.split(pkg.relativeDir).join('/'),
    'files': files,
    'dependencies': pkg.dependencySpecs,
    'flutter_sha256': sha256OfBytes(canonicalJson(pkg.flutterSection)),
    'environment': pkg.pubspec['environment'],
    'native_sha256': _hashOfMap(native),
    'other_sha256': _hashOfMap(other),
    'other_files': other.keys.toList(),
  };
}

/// Captures the snapshot of the project in [projectDir] (does not write anything).
Map<String, Object?> captureFeatureSnapshot(String projectDir, {DateTime? now}) {
  final project = ProjectPackages.load(projectDir);
  final graph = FeatureGraph.build(project);
  final app = project.app;
  final lock = _findLock(project);
  final registry = File(p.join(app.libDir, registryFileName));
  return {
    'format': featureSnapshotFormat,
    'created_at': '${(now ?? DateTime.now()).toUtc().toIso8601String().split('.').first}Z',
    'app': app.name,
    'lock_sha256': lock == null ? null : sha256OfBytes(File(lock).readAsBytesSync()),
    'registry_sha256': registry.existsSync() ? sha256OfBytes(registry.readAsBytesSync()) : null,
    'packages': {
      app.name: {'role': PackageRole.app.name, ..._packageSnapshot(app, isApp: true)},
      for (final l in project.local.values)
        l.name: {
          'role': graph.roles[l.name]!.name,
          if (graph.internalOwner[l.name] != null) 'feature': graph.internalOwner[l.name],
          if (graph.features[l.name] != null) 'entry': graph.features[l.name]!.toJson(),
          ..._packageSnapshot(l, isApp: false),
        },
    },
  };
}

String? _findLock(ProjectPackages project) {
  final own = p.join(project.projectDir, 'pubspec.lock');
  if (File(own).existsSync()) return own;
  // Pub workspace: the lock file sits next to the package config's .dart_tool.
  final ws = p.join(p.dirname(p.dirname(project.config.path)), 'pubspec.lock');
  return File(ws).existsSync() ? ws : null;
}

/// Records the feature snapshot of [projectDir] for the release in [releaseDir]. The release
/// command (4D) calls this right after the store build. Returns the file path.
String recordFeatureSnapshot(String projectDir, String releaseDir, {DateTime? now}) {
  final snap = captureFeatureSnapshot(projectDir, now: now);
  Directory(releaseDir).createSync(recursive: true);
  final path = p.join(releaseDir, featureSnapshotFileName);
  File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(snap));
  return path;
}

/// Reads the snapshot of a release, or throws a clear error.
Map<String, Object?> loadFeatureSnapshot(String releaseDir) {
  final f = File(p.join(releaseDir, featureSnapshotFileName));
  if (!f.existsSync()) {
    throw CliException(
      'The release in $releaseDir has no $featureSnapshotFileName, so the CLI cannot tell what changed '
      'since the store build. Releases made with `flutter_ota release android` record it '
      'automatically; make a new store release.',
    );
  }
  final j = jsonDecode(f.readAsStringSync());
  if (j is! Map<String, Object?> || j['format'] != featureSnapshotFormat || j['packages'] is! Map) {
    throw CliException('${f.path} is not a supported feature snapshot.');
  }
  return j;
}

/// What changed in one package since the release.
class PackageChange {
  PackageChange(this.name);
  final String name;
  final changedFiles = <String>[];
  final addedDependencies = <String>[];
  final removedDependencies = <String>[];
  final changedDependencies = <String>[];
  bool flutterSectionChanged = false;
  bool environmentChanged = false;
  bool nativeChanged = false;
  bool otherFilesChanged = false;
  bool added = false;
  bool removed = false;

  bool get sourceChanged => changedFiles.isNotEmpty;
  bool get pubspecChanged =>
      addedDependencies.isNotEmpty ||
      removedDependencies.isNotEmpty ||
      changedDependencies.isNotEmpty ||
      flutterSectionChanged ||
      environmentChanged;
  bool get any => sourceChanged || pubspecChanged || nativeChanged || otherFilesChanged || added || removed;

  String describe() => [
    if (added) 'new package (not in the store build)',
    if (removed) 'package removed',
    if (changedFiles.isNotEmpty)
      '${changedFiles.length} file(s) changed: ${changedFiles.take(4).join(', ')}${changedFiles.length > 4 ? ', ...' : ''}',
    if (addedDependencies.isNotEmpty) 'dependencies added: ${addedDependencies.join(', ')}',
    if (removedDependencies.isNotEmpty) 'dependencies removed: ${removedDependencies.join(', ')}',
    if (changedDependencies.isNotEmpty) 'dependency constraints changed: ${changedDependencies.join(', ')}',
    if (flutterSectionChanged) 'pubspec flutter: section (assets, fonts, plugin) changed',
    if (environmentChanged) 'pubspec environment changed',
    if (nativeChanged) 'native code changed (${nativeDirNames.join('/')})',
    if (otherFilesChanged) 'files outside lib/ changed (assets, fonts, ...)',
  ].join('; ');
}

/// Differences between the release snapshot and the current project.
class SnapshotDiff {
  SnapshotDiff(this.release, this.current);
  final Map<String, Object?> release;
  final Map<String, Object?> current;
  final packages = <String, PackageChange>{};
  bool lockChanged = false;
  bool registryChanged = false;

  Iterable<PackageChange> get changed => packages.values.where((c) => c.any);

  String? releaseRole(String name) => ((release['packages']! as Map)[name] as Map?)?['role'] as String?;
}

SnapshotDiff diffFeatureSnapshots(Map<String, Object?> release, Map<String, Object?> current) {
  final d = SnapshotDiff(release, current);
  d.lockChanged = release['lock_sha256'] != current['lock_sha256'];
  d.registryChanged = release['registry_sha256'] != current['registry_sha256'];
  final a = (release['packages']! as Map).cast<String, Object?>();
  final b = (current['packages']! as Map).cast<String, Object?>();
  for (final name in {...a.keys, ...b.keys}) {
    final c = PackageChange(name);
    d.packages[name] = c;
    final x = a[name] as Map?;
    final y = b[name] as Map?;
    if (x == null) {
      c.added = true;
      continue;
    }
    if (y == null) {
      c.removed = true;
      continue;
    }
    final fx = (x['files'] as Map).cast<String, Object?>();
    final fy = (y['files'] as Map).cast<String, Object?>();
    c.changedFiles.addAll(({...fx.keys, ...fy.keys}.where((k) => fx[k] != fy[k]).toList()..sort()));
    final dx = ((x['dependencies'] as Map?) ?? const {}).cast<String, Object?>();
    final dy = ((y['dependencies'] as Map?) ?? const {}).cast<String, Object?>();
    c.addedDependencies.addAll(dy.keys.where((k) => !dx.containsKey(k)).toList()..sort());
    c.removedDependencies.addAll(dx.keys.where((k) => !dy.containsKey(k)).toList()..sort());
    c.changedDependencies.addAll(
      dx.keys.where((k) => dy.containsKey(k) && canonicalJsonString(dx[k]) != canonicalJsonString(dy[k])).toList()
        ..sort(),
    );
    c.flutterSectionChanged = x['flutter_sha256'] != y['flutter_sha256'];
    c.environmentChanged = canonicalJsonString(x['environment']) != canonicalJsonString(y['environment']);
    c.nativeChanged = x['native_sha256'] != y['native_sha256'];
    c.otherFilesChanged = x['other_sha256'] != y['other_sha256'];
  }
  return d;
}
