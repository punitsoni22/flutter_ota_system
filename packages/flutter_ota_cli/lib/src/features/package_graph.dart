// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../errors.dart';
import '../release/app_project.dart' show otaWorkDirName;
import '../release/ota_entry.dart' show loaderPackageName;

/// One entry of `.dart_tool/package_config.json`.
class PackageConfigEntry {
  PackageConfigEntry(this.name, this.rootDir, this.packageUri, this.languageVersion, this.raw);

  final String name;

  /// Absolute directory of the package (resolved `rootUri`).
  final String rootDir;
  final String packageUri;
  final String? languageVersion;
  final Map<String, Object?> raw;

  String get libDir => p.normalize(p.join(rootDir, packageUri));
}

/// A parsed `.dart_tool/package_config.json`.
class PackageConfig {
  PackageConfig(this.path, this.packages, this.raw);

  /// Reads the package config that applies to [packageDir]: its own `.dart_tool/` or that of a
  /// parent directory (pub workspaces).
  static PackageConfig? find(String packageDir) {
    var dir = p.normalize(p.absolute(packageDir));
    while (true) {
      final f = File(p.join(dir, '.dart_tool', 'package_config.json'));
      if (f.existsSync()) return read(f.path);
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  static PackageConfig read(String path) {
    final Object? json;
    try {
      json = jsonDecode(File(path).readAsStringSync());
    } on FormatException catch (e) {
      throw CliException('$path is not valid JSON (${e.message}). Run `flutter pub get`.');
    }
    if (json is! Map<String, Object?> || json['packages'] is! List) {
      throw CliException('$path is not a package config. Run `flutter pub get`.');
    }
    final base = Uri.file(path);
    final out = <String, PackageConfigEntry>{};
    for (final e in (json['packages']! as List).whereType<Map<String, Object?>>()) {
      final name = e['name'];
      final rootUri = e['rootUri'];
      if (name is! String || rootUri is! String) continue;
      var root = base.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
      final dir = p.normalize(root.toFilePath());
      out[name] = PackageConfigEntry(
        name,
        dir.endsWith(p.separator) && dir.length > 1 ? dir.substring(0, dir.length - 1) : dir,
        (e['packageUri'] as String?) ?? 'lib/',
        e['languageVersion'] as String?,
        e,
      );
    }
    return PackageConfig(path, out, json);
  }

  final String path;
  final Map<String, PackageConfigEntry> packages;
  final Map<String, Object?> raw;
}

/// A package whose sources live inside the project (a path dependency or workspace member).
class LocalPackage {
  LocalPackage({required this.name, required this.dir, required this.relativeDir, required this.pubspec});

  /// Reads `<dir>/pubspec.yaml`.
  factory LocalPackage.read(String dir, String projectDir) {
    final f = File(p.join(dir, 'pubspec.yaml'));
    final Object? y;
    try {
      y = loadYaml(f.readAsStringSync());
    } on YamlException catch (e) {
      throw CliException('${f.path} is not valid YAML: ${e.message}');
    } on FileSystemException {
      throw CliException('${f.path} is missing.');
    }
    if (y is! YamlMap || y['name'] is! String) throw CliException('${f.path} has no `name`.');
    return LocalPackage(
      name: y['name'] as String,
      dir: dir,
      relativeDir: p.relative(dir, from: projectDir),
      pubspec: _plain(y) as Map<String, Object?>,
    );
  }

  final String name;
  final String dir;

  /// Directory relative to the project root (`.` for the app itself).
  final String relativeDir;
  final Map<String, Object?> pubspec;

  Map<String, Object?> _section(String key) {
    final v = pubspec[key];
    return v is Map<String, Object?> ? v : const {};
  }

  /// Names in `dependencies:`.
  Set<String> get dependencies => _section('dependencies').keys.toSet();

  /// Names in `dev_dependencies:`.
  Set<String> get devDependencies => _section('dev_dependencies').keys.toSet();

  /// The `dependencies:` section as written (used to detect dependency changes).
  Map<String, Object?> get dependencySpecs => _section('dependencies');

  /// The `flutter:` section (assets, fonts, plugin).
  Map<String, Object?> get flutterSection => _section('flutter');

  bool get isPlugin => flutterSection['plugin'] != null;

  bool get usesBuildRunner => dependencies.contains('build_runner') || devDependencies.contains('build_runner');

  /// Platform directories with native code.
  List<String> get nativeDirs => [
    for (final d in nativeDirNames)
      if (Directory(p.join(dir, d)).existsSync()) d,
  ];

  String get libDir => p.join(dir, 'lib');
}

/// Directories whose contents are native (platform) code: a change needs a store release.
const nativeDirNames = ['android', 'ios', 'linux', 'macos', 'windows', 'web', 'src', 'cpp'];

Object? _plain(Object? y) {
  if (y is YamlMap) return {for (final e in y.entries) '${e.key}': _plain(e.value)};
  if (y is YamlList) return [for (final v in y) _plain(v)];
  return y;
}

/// Whether the package [name] at [rootDir] belongs to flutter_ota itself rather than to the
/// developer: the `dynamic_modules` loader package (wherever it lives), or anything below
/// `<project>/.flutter_ota/` (where the release command copies it). Such packages are
/// compiled into the store build, are never features and are never patched or renamed.
bool isToolOwnedPackage(String name, String rootDir, String projectDir) =>
    name == loaderPackageName || p.isWithin(p.join(projectDir, otaWorkDirName), rootDir);

/// The packages of an app project: the app itself, its local packages (inside the project
/// directory) and the resolved package config.
class ProjectPackages {
  ProjectPackages(this.projectDir, this.app, this.local, this.config, this.outsideProject, {this.toolOwned = const []});

  /// Loads [projectDir] (the Flutter app root). Requires `flutter pub get` to have run.
  static ProjectPackages load(String projectDir) {
    final root = p.normalize(p.absolute(projectDir));
    final app = LocalPackage.read(root, root);
    final config = PackageConfig.find(root);
    if (config == null || !config.packages.containsKey(app.name)) {
      throw CliException(
        'No package config for ${app.name} (.dart_tool/package_config.json). '
        'Run `flutter pub get` in $root first.',
      );
    }
    final local = <String, LocalPackage>{};
    final outside = <String>[];
    final toolOwned = <String>[];
    for (final e in config.packages.values) {
      if (e.name == app.name) continue;
      if (isToolOwnedPackage(e.name, e.rootDir, root)) {
        toolOwned.add(e.name);
        continue;
      }
      final inProject = p.isWithin(root, e.rootDir);
      if (!inProject) {
        if (!_isHostedOrSdk(e.rootDir) && File(p.join(e.rootDir, 'pubspec.yaml')).existsSync()) {
          outside.add(e.name);
        }
        continue;
      }
      if (!File(p.join(e.rootDir, 'pubspec.yaml')).existsSync()) continue;
      final pkg = LocalPackage.read(e.rootDir, root);
      local[pkg.name] = pkg;
    }
    outside.sort();
    toolOwned.sort();
    return ProjectPackages(root, app, local, config, outside, toolOwned: toolOwned);
  }

  final String projectDir;
  final LocalPackage app;
  final Map<String, LocalPackage> local;
  final PackageConfig config;

  /// Path dependencies outside the project directory: always treated as host-owned.
  final List<String> outsideProject;

  /// Packages that belong to flutter_ota itself (see [isToolOwnedPackage]): always host-owned,
  /// never in [local], so they are never features and never patched or renamed.
  final List<String> toolOwned;

  /// Direct dependents of [name] among the app and the local packages.
  Set<String> dependentsOf(String name) => {
    if (app.dependencies.contains(name)) app.name,
    for (final l in local.values)
      if (l.dependencies.contains(name)) l.name,
  };
}

bool _isHostedOrSdk(String dir) {
  final parts = p.split(dir);
  return parts.contains('.pub-cache') ||
      parts.contains('hosted') ||
      parts.contains('git') ||
      (parts.contains('packages') && parts.contains('flutter')) ||
      parts.contains('sky_engine');
}
