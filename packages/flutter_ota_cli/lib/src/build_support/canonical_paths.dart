// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';

/// Default canonical build root. It must be the same absolute path on every machine, because the
/// store build's `link.dill` and every patch module record source paths below it.
const defaultCanonicalBuildRoot = '/tmp/flutter_ota-build';

/// Environment variable that moves the canonical build root (tests; machines without `/tmp`).
/// Builds made with another root record other paths, so use the same value for a release and
/// its patches.
const canonicalBuildRootEnv = 'FLUTTER_OTA_BUILD_ROOT';

/// Symlink names inside the canonical root.
const canonToolchain = 'toolchain';
const canonPubCache = 'pub-cache';
const canonWorkspace = 'workspace';

/// The release's build copy inside the canonical root: a real directory, never a symlink.
const canonProjectCopy = 'project';

/// The canonical build root: a directory owned by the current user that holds symlinks
///
///     <root>/toolchain  -> the resolved toolchain directory
///     <root>/pub-cache  -> the pub cache
///     <root>/workspace  -> the folder that contains the app and all its path packages
///
/// so that compiled kernel and bytecode contain `<root>/...` paths instead of the developer's own
/// home directory. One build at a time holds `<root>/.lock` (a second build waits).
///
/// Used by `release android` (4D) and `patch android` (4E): both must link the same names.
class CanonicalBuildRoot {
  CanonicalBuildRoot._(this.path, this._lock);

  /// Creates (mode 0700) or checks the root and takes its lock. Refuses a root that is a symlink
  /// or that belongs to another user (somebody could redirect the build otherwise).
  static CanonicalBuildRoot acquire(Map<String, String> env, {void Function(String)? log}) {
    final raw = env[canonicalBuildRootEnv];
    final root = (raw == null || raw.isEmpty) ? defaultCanonicalBuildRoot : p.normalize(p.absolute(raw));
    final link = Link(root);
    if (link.existsSync() && FileSystemEntity.isLinkSync(root)) {
      throw CliException('$root is a symlink. Remove it (it must be a real directory owned by you).');
    }
    final dir = Directory(root);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    Process.runSync('chmod', ['0700', root]);
    final owner = _ownerUid(root);
    final me = _currentUid();
    if (owner == null || me == null || owner != me) {
      throw CliException(
        '$root belongs to another user. Remove it, or set $canonicalBuildRootEnv to a directory '
        'you own (use the same value for the release and its patches).',
      );
    }
    final lockFile = File(p.join(root, '.lock')).openSync(mode: FileMode.append);
    try {
      lockFile.lockSync(FileLock.exclusive);
    } on FileSystemException {
      log?.call('Another flutter_ota build is running; waiting for it to finish...');
      lockFile.lockSync(FileLock.blockingExclusive);
    }
    return CanonicalBuildRoot._(root, lockFile);
  }

  final String path;
  final RandomAccessFile _lock;

  String get toolchain => p.join(path, canonToolchain);
  String get pubCache => p.join(path, canonPubCache);
  String get workspace => p.join(path, canonWorkspace);

  /// The real directory that holds the release's build copy (see `build_copy.dart`). It is not a
  /// symlink, so the Flutter tool's absolute paths of the store build are neutral.
  String get projectCopy => p.join(path, canonProjectCopy);

  /// Points `<root>/<name>` at [target] (replacing an old link).
  String link(String name, String target) {
    final l = Link(p.join(path, name));
    final real = Directory(target).resolveSymbolicLinksSync();
    if (FileSystemEntity.isLinkSync(l.path)) {
      if (l.targetSync() == real) return l.path;
      l.deleteSync();
    } else if (FileSystemEntity.typeSync(l.path) != FileSystemEntityType.notFound) {
      throw CliException('${l.path} exists and is not a symlink. Remove it.');
    }
    l.createSync(real);
    return l.path;
  }

  void release() {
    try {
      _lock.unlockSync();
    } on FileSystemException {
      // already unlocked
    }
    _lock.closeSync();
  }

  static int? _ownerUid(String path) {
    final r = Process.runSync('stat', ['-c', '%u', path]);
    return r.exitCode == 0 ? int.tryParse((r.stdout as String).trim()) : null;
  }

  static int? _currentUid() {
    final r = Process.runSync('id', ['-u']);
    return r.exitCode == 0 ? int.tryParse((r.stdout as String).trim()) : null;
  }
}

/// Real-path prefix -> canonical-path prefix. The longest matching prefix wins.
class PathMapping {
  PathMapping(Map<String, String> pairs)
    : _pairs = pairs.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length));

  final List<MapEntry<String, String>> _pairs;

  /// Maps an absolute real path, or returns null when no prefix matches.
  String? map(String real) {
    for (final e in _pairs) {
      if (real == e.key) return e.value;
      if (p.isWithin(e.key, real)) return p.join(e.value, p.relative(real, from: e.key));
    }
    return null;
  }
}

/// A package from `.dart_tool/package_config.json` with its real root directory.
class ConfigPackage {
  ConfigPackage(this.name, this.root, this.json);
  final String name;

  /// Absolute, symlink-free root directory.
  final String root;
  final Map<String, Object?> json;
}

/// Reads `.dart_tool/package_config.json` and resolves every root to a real absolute path.
List<ConfigPackage> readPackageConfig(String packageConfigPath) {
  final Object? j;
  try {
    j = jsonDecode(File(packageConfigPath).readAsStringSync());
  } on Object catch (e) {
    throw CliException('Cannot read $packageConfigPath: $e');
  }
  if (j is! Map || j['packages'] is! List) throw CliException('$packageConfigPath is not a package config.');
  final base = p.dirname(p.absolute(packageConfigPath));
  final out = <ConfigPackage>[];
  for (final e in (j['packages'] as List).cast<Map<String, Object?>>()) {
    final uri = e['rootUri'] as String;
    final abs = uri.startsWith('file:')
        ? Uri.parse(uri).toFilePath()
        : p.normalize(p.join(base, Uri.decodeComponent(uri)));
    final d = Directory(abs);
    final real = d.existsSync() ? d.resolveSymbolicLinksSync() : p.normalize(abs);
    out.add(ConfigPackage(e['name'] as String, real, e));
  }
  return out;
}

/// The folder that holds the app ([projectReal]) and all its path packages: the common ancestor of
/// the app and every package of [packages] that is not inside the toolchain or the pub cache.
/// Shared by `release android` and `patch android`, which must link the same workspace.
String appWorkspace({
  required String projectReal,
  required Iterable<ConfigPackage> packages,
  required String toolchainReal,
  required String? pubCacheReal,
  required String? home,
}) {
  final local = [
    for (final pkg in packages)
      if (!p.isWithin(toolchainReal, pkg.root) && (pubCacheReal == null || !p.isWithin(pubCacheReal, pkg.root)))
        pkg.root,
  ];
  final workspace = commonAncestor([projectReal, ...local]);
  if (workspace == p.separator || workspace == home) {
    throw CliException(
      'The app and its path packages share no folder below your home directory ($workspace).\n'
      'Keep path packages inside one project folder.',
    );
  }
  return workspace;
}

/// The deepest directory that contains every path in [paths].
String commonAncestor(Iterable<String> paths) {
  List<String>? common;
  for (final x in paths) {
    final parts = p.split(p.normalize(x));
    if (common == null) {
      common = parts;
      continue;
    }
    var i = 0;
    while (i < common.length && i < parts.length && common[i] == parts[i]) {
      i++;
    }
    common = common.sublist(0, i);
  }
  if (common == null || common.isEmpty) return p.separator;
  return p.joinAll(common);
}

/// Writes a package config whose roots all live below the canonical root. Every package must be
/// inside the toolchain, the pub cache or the workspace, else [CliException].
String canonicalPackageConfig(List<ConfigPackage> packages, PathMapping mapping) {
  final out = <Map<String, Object?>>[];
  for (final pkg in packages) {
    final mapped = mapping.map(pkg.root);
    if (mapped == null) {
      throw CliException(
        'Package ${pkg.name} lives at ${pkg.root}, outside the toolchain, the pub cache and the '
        'app workspace. Move it next to the app (path dependency) or depend on a published version.',
      );
    }
    out.add({...pkg.json, 'rootUri': Uri.directory(mapped).toString()});
  }
  return '${const JsonEncoder.withIndent('  ').convert({'configVersion': 2, 'packages': out})}\n';
}
