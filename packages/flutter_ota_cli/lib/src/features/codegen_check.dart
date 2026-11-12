// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Stale generated-code detection (Phase 4 spike S1, gap 3).
//
// Problem: a developer changes `@JsonKey(name: 'price')` but forgets to re-run build_runner.
// Every compiler accepts the old generated file, so the patch would silently use the old JSON
// key. Check: copy the package (and the local packages it resolves against) into a clean temp
// directory, run `dart run build_runner build --delete-conflicting-outputs` there, and compare
// every file under lib/ with the developer's copy. Any difference means the checked-in generated
// code is stale, and the patch is refused with the command to fix it.
//
// The developer's project is never changed. A successful check is cached by a hash of the
// package's inputs, so an unchanged package is not regenerated again.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../errors.dart';
import '../patch/process.dart';
import '../toolchain/canonical_json.dart';
import 'package_graph.dart';
import 'snapshot.dart';

/// Minimum freezed version on Dart 3.13 (freezed 3.x writes `final` parameters; spike S1).
const minFreezedVersion = [4, 0, 3];

/// Refuses known-bad code generator versions for [pkg] (resolved versions from [lockPath]).
List<String> codegenVersionProblems(LocalPackage pkg, String? lockPath) {
  if (lockPath == null) return const [];
  final uses =
      pkg.dependencies.contains('freezed') ||
      pkg.devDependencies.contains('freezed') ||
      pkg.dependencies.contains('freezed_annotation');
  if (!uses) return const [];
  final lock = loadYaml(File(lockPath).readAsStringSync());
  final pkgs = lock is YamlMap ? lock['packages'] : null;
  final freezed = pkgs is YamlMap ? pkgs['freezed'] : null;
  final version = freezed is YamlMap ? freezed['version'] : null;
  if (version is! String) return const [];
  final parts = version.split(RegExp(r'[.+-]')).take(3).map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    if (parts[i] > minFreezedVersion[i]) return const [];
    if (parts[i] < minFreezedVersion[i]) {
      return [
        '${pkg.name} uses freezed $version. Dart 3.13 rejects the code freezed 3.x generates '
            '(`final` constructor parameters). Upgrade to freezed >= ${minFreezedVersion.join('.')} '
            'and re-run build_runner, then make a new store release.',
      ];
    }
  }
  return const [];
}

/// Checks that the generated files of [pkg] are up to date.
class CodegenChecker {
  CodegenChecker({
    required this.project,
    required this.dartBin,
    required this.flutterSdk,
    required this.run,
    required this.workDir,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final ProjectPackages project;
  final String dartBin;
  final String flutterSdk;
  final ToolRunner run;

  /// Scratch directory for the clean copy (deleted afterwards).
  final String workDir;
  final Map<String, String> environment;

  String get _cachePath => p.join(project.projectDir, '.dart_tool', 'flutter_ota', 'codegen_check.json');

  /// Hash of everything build_runner reads for [pkg]: its files, the lock file and every local
  /// package's lib/ (a generator may read types from a dependency).
  String inputKey(LocalPackage pkg) {
    final lock = File(p.join(project.projectDir, 'pubspec.lock'));
    return sha256OfBytes(
      canonicalJson({
        'pkg': pkg.name,
        'files': hashTree(pkg.dir, include: (rel) => !rel.startsWith('.dart_tool/')),
        'lock': lock.existsSync() ? sha256OfBytes(lock.readAsBytesSync()) : null,
        'local': {for (final l in project.local.values) l.name: hashTree(l.libDir)},
        'dart': dartBin,
      }),
    );
  }

  /// Returns the stale files (relative to the package), or an empty list when up to date.
  /// Throws [CliException] when build_runner fails.
  Future<List<String>> staleFiles(LocalPackage pkg) async {
    if (!pkg.usesBuildRunner) return const [];
    final key = inputKey(pkg);
    final cache = _readCache();
    if (cache[pkg.name] == key) return const [];

    final copyRoot = p.join(workDir, 'codegen-${pkg.name}');
    final dir = Directory(copyRoot);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    try {
      _copyProject(copyRoot);
      final pkgCopy = p.join(copyRoot, pkg.relativeDir);
      final r = await run(
        dartBin,
        ['run', 'build_runner', 'build', '--delete-conflicting-outputs'],
        workingDirectory: pkgCopy,
        environment: {...environment, 'FLUTTER_ROOT': flutterSdk, 'PUB_ENVIRONMENT': 'flutter_ota:codegen_check'},
      );
      if (r.exitCode != 0) {
        throw CliException(
          'build_runner failed for ${pkg.name} in a clean copy, so its generated code cannot be checked:\n'
          '${tail('${r.stdout}\n${r.stderr}', 20)}\n'
          'Fix the error, then run in ${pkg.relativeDir}:  dart run build_runner build --delete-conflicting-outputs',
        );
      }
      final mine = hashTree(pkg.libDir);
      final fresh = hashTree(p.join(pkgCopy, 'lib'));
      final stale = {...mine.keys, ...fresh.keys}.where((k) => mine[k] != fresh[k]).map((k) => 'lib/$k').toList()
        ..sort();
      if (stale.isEmpty) {
        cache[pkg.name] = key;
        _writeCache(cache);
      }
      return stale;
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }

  Map<String, String> _readCache() {
    try {
      return (jsonDecode(File(_cachePath).readAsStringSync()) as Map).cast<String, String>();
    } on Object {
      return {};
    }
  }

  void _writeCache(Map<String, String> c) {
    File(_cachePath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(c));
  }

  /// Copies the app's pub files and every local package (sources and pub state, no build
  /// outputs, no native code) to [to], keeping relative paths and modification times so pub
  /// sees an up-to-date resolution and does not resolve again.
  void _copyProject(String to) {
    final root = project.projectDir;
    for (final name in ['pubspec.yaml', 'pubspec.lock']) {
      _copyFile(p.join(root, name), p.join(to, name));
    }
    _copyDartTool(p.join(root, '.dart_tool'), p.join(to, '.dart_tool'));
    for (final l in project.local.values) {
      _copyPackage(l.dir, p.join(to, l.relativeDir));
    }
  }

  void _copyPackage(String from, String to) {
    for (final e in Directory(from).listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (name == '.dart_tool') {
          _copyDartTool(e.path, p.join(to, name));
        } else if (!const {'build', '.git', '.idea', ...nativeDirNames}.contains(name)) {
          _copyTree(e.path, p.join(to, name));
        }
      } else if (e is File) {
        _copyFile(e.path, p.join(to, name));
      }
    }
  }

  void _copyDartTool(String from, String to) {
    for (final name in ['package_config.json', 'package_graph.json', 'version']) {
      _copyFile(p.join(from, name), p.join(to, name));
    }
  }

  void _copyTree(String from, String to) {
    for (final e in Directory(from).listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (name == 'build' || name == '.dart_tool') continue;
        _copyTree(e.path, p.join(to, name));
      } else if (e is File) {
        _copyFile(e.path, p.join(to, name));
      }
    }
  }

  void _copyFile(String from, String to) {
    final f = File(from);
    if (!f.existsSync()) return;
    Directory(p.dirname(to)).createSync(recursive: true);
    f.copySync(to);
    File(to).setLastModifiedSync(f.lastModifiedSync());
  }
}
