// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../errors.dart';

/// Names skipped at any depth: tool caches and VCS data that hold absolute paths or are rebuilt.
const _skipAnywhere = {'.dart_tool', '.git', '.gradle', '.cxx'};

/// Entries skipped next to a `pubspec.yaml` (a package root): build outputs, iOS (Android builds
/// only), files the Flutter tool regenerates with absolute paths, and the release baselines.
const _skipAtPackageRoot = {'build', 'ios', '.flutter-plugins', '.flutter-plugins-dependencies'};

/// Paths relative to a package root that are skipped.
const _skipRelToPackageRoot = {'android/local.properties', '.flutter_ota/releases'};

/// Whether [rel] (relative to its nearest package root, `/`-separated) is left out of the build copy.
bool excludedFromBuildCopy(String rel) {
  final parts = rel.split('/');
  if (parts.any(_skipAnywhere.contains)) return true;
  if (parts.length == 1 && _skipAtPackageRoot.contains(parts.single)) return true;
  return _skipRelToPackageRoot.any((x) => rel == x || rel.startsWith('$x/'));
}

/// A copy of the app workspace at a neutral real path (`<canonical root>/project`).
///
/// The Flutter tool writes `.dart_tool/flutter_build/dart_plugin_registrant.dart` into the app
/// folder and compiles it by its absolute (symlink-free) path, so a store build made in the
/// developer's folder records that folder (often below `/home/<user>`) in `libapp.so`. The release
/// command therefore builds in this copy; only the APK/AAB is copied back.
class BuildCopy {
  BuildCopy._(this.root, this.appDir, this.realWorkspace, this.realApp);

  /// The copy of the workspace (`<canonical root>/project`).
  final String root;

  /// The app inside the copy (same relative place as in the workspace).
  final String appDir;

  /// The real workspace and app the copy was made from.
  final String realWorkspace;
  final String realApp;

  /// Copies [workspace] (the folder that holds the app [app] and all its path packages) to [dest],
  /// replacing an old copy. Leaves out build outputs and caches ([excludedFromBuildCopy]) and any
  /// folder in [skip] (for example the canonical build root itself). Absolute `path:` dependencies
  /// that point into the workspace are rewritten to relative ones so they resolve in the copy.
  static BuildCopy create({
    required String workspace,
    required String app,
    required String dest,
    Iterable<String> skip = const [],
  }) {
    final ws = p.normalize(workspace);
    final realApp = p.normalize(app);
    if (!p.equals(ws, realApp) && !p.isWithin(ws, realApp)) {
      throw CliException('The app $realApp is not inside its workspace $ws.');
    }
    final d = p.normalize(dest);
    // A copy inside the workspace (a build root below the project) is skipped while copying.
    if (p.equals(d, ws) || p.isWithin(d, ws)) {
      throw CliException('The build copy $d must not overlap the workspace $ws.');
    }
    remove(d);
    Directory(d).createSync(recursive: true);
    final skipped = {...skip.map(p.normalize), d};
    _copyDir(ws, d, ws, d, skipped, packageRoot: File(p.join(ws, 'pubspec.yaml')).existsSync() ? ws : null);
    final copy = BuildCopy._(d, p.join(d, p.relative(realApp, from: ws)), ws, realApp);
    copy._rewriteAbsolutePathDependencies();
    return copy;
  }

  /// Deletes a build copy (a symlink at [path] is only unlinked).
  static void remove(String path) {
    final t = FileSystemEntity.typeSync(path, followLinks: false);
    if (t == FileSystemEntityType.notFound) return;
    if (t == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
    } else {
      File(path).deleteSync();
    }
  }

  static void _copyDir(String src, String dst, String ws, String copyRoot, Set<String> skip, {String? packageRoot}) {
    final entries = Directory(src).listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = p.basename(e.path);
      final rel = packageRoot == null ? name : p.posix.joinAll(p.split(p.relative(e.path, from: packageRoot)));
      if (_skipAnywhere.contains(name) || (packageRoot != null && excludedFromBuildCopy(rel))) continue;
      if (skip.contains(p.normalize(e.path))) continue;
      final target = p.join(dst, name);
      final type = FileSystemEntity.typeSync(e.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        var to = Link(e.path).targetSync();
        // A link to an absolute place inside the workspace points to the same place in the copy.
        if (p.isAbsolute(to) && (p.equals(to, ws) || p.isWithin(ws, to))) {
          to = p.join(copyRoot, p.relative(to, from: ws));
        }
        Link(target).createSync(to);
      } else if (type == FileSystemEntityType.directory) {
        Directory(target).createSync();
        final isPackage = File(p.join(e.path, 'pubspec.yaml')).existsSync();
        _copyDir(e.path, target, ws, copyRoot, skip, packageRoot: isPackage ? e.path : packageRoot);
      } else if (type == FileSystemEntityType.file) {
        // File.copySync keeps the permission bits (gradlew stays executable).
        File(e.path).copySync(target);
      }
    }
  }

  void _rewriteAbsolutePathDependencies() {
    for (final f in Directory(root).listSync(recursive: true, followLinks: false).whereType<File>()) {
      final name = p.basename(f.path);
      if (name != 'pubspec.yaml' && name != 'pubspec_overrides.yaml') continue;
      final out = rewritePathDependencies(
        f.readAsStringSync(),
        realDir: p.join(realWorkspace, p.relative(p.dirname(f.path), from: root)),
        realWorkspace: realWorkspace,
      );
      if (out != null) f.writeAsStringSync(out);
    }
  }

  /// Copies the store file [builtInCopy] (inside [appDir]) to the same relative place in the real
  /// app and returns that path.
  String copyOutputBack(String builtInCopy) {
    if (!p.isWithin(appDir, builtInCopy)) throw CliException('$builtInCopy is not inside the build copy.');
    final dest = p.join(realApp, p.relative(builtInCopy, from: appDir));
    Directory(p.dirname(dest)).createSync(recursive: true);
    File(builtInCopy).copySync(dest);
    return dest;
  }
}

/// Rewrites `path:` dependencies of a `pubspec.yaml` (or `pubspec_overrides.yaml`) whose absolute
/// path lies inside [realWorkspace] to paths relative to [realDir] (the pubspec's folder), so they
/// resolve inside a copy with the same layout. Returns null when nothing changes.
String? rewritePathDependencies(String text, {required String realDir, required String realWorkspace}) {
  final Object? doc;
  try {
    doc = loadYamlNode(text);
  } on YamlException {
    return null; // pub reports it in the copy
  }
  if (doc is! YamlMap) return null;
  final edits = <(int, int, String)>[];
  for (final section in ['dependencies', 'dev_dependencies', 'dependency_overrides']) {
    final deps = doc.nodes[section];
    if (deps is! YamlMap) continue;
    for (final dep in deps.nodes.values) {
      if (dep is! YamlMap) continue;
      final node = dep.nodes['path'];
      if (node is! YamlScalar || node.value is! String) continue;
      final value = node.value as String;
      if (!p.isAbsolute(value)) continue;
      final abs = p.normalize(value);
      if (!p.equals(abs, realWorkspace) && !p.isWithin(realWorkspace, abs)) continue;
      final rel = p.posix.joinAll(p.split(p.relative(abs, from: realDir)));
      edits.add((node.span.start.offset, node.span.end.offset, "'$rel'"));
    }
  }
  if (edits.isEmpty) return null;
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  var out = text;
  for (final (start, end, s) in edits) {
    out = out.replaceRange(start, end, s);
  }
  return out;
}
