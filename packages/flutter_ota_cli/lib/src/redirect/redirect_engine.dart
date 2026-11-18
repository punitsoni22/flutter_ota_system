// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// EXPERIMENTAL second patch engine: "redirect" (adaptive patch levels).
//
// Instead of feature packages and slots, the store build is prepared so that every function and
// initializer of the app can be replaced (a hidden typed slot + a cheap check), and a patch carries
// only what changed: replaced bodies, re-pointed call sites, side fields for new fields, class
// copies for structure changes. See prototypes/redirect_stubs/README.md.
//
// The work is done by the `ota_redirect` tool (prototypes/redirect_stubs/tool), run with the
// toolchain's Dart. Its location comes from $redirectToolEnv while the engine is experimental.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../features/snapshot.dart';

const featureEngine = 'feature';
const redirectEngine = 'redirect';
const patchEngines = [featureEngine, redirectEngine];

/// Dynamic interface scope of a store build (`release android --interface-scope`, EXPERIMENTAL).
const interfaceScopeAll = 'all';
const interfaceScopeApp = 'app';
const interfaceScopes = [interfaceScopeAll, interfaceScopeApp];

/// Environment variable with the folder of the `ota_redirect` tool.
const redirectToolEnv = 'FLUTTER_OTA_REDIRECT_TOOL';

/// Folder in a release baseline with what redirect patches diff against.
const redirectBaselineDir = 'redirect';

String redirectToolDir(Map<String, String> env) {
  final v = env[redirectToolEnv];
  if (v == null || v.isEmpty || !File(p.join(v, 'bin', 'ota_redirect.dart')).existsSync()) {
    throw CliException(
      'The redirect engine is experimental and needs the ota_redirect tool.\n'
      'Set $redirectToolEnv to its folder (prototypes/redirect_stubs/tool in the repository).',
    );
  }
  return p.normalize(p.absolute(v));
}

/// Runs `dart run <tool>/bin/ota_redirect.dart <args>` with [dartBin] and returns its output.
Future<String> runRedirectTool({
  required String dartBin,
  required String toolDir,
  required List<String> args,
  required Map<String, String> environment,
}) async {
  if (!File(p.join(toolDir, '.dart_tool', 'package_config.json')).existsSync()) {
    final g = await Process.run(dartBin, ['pub', 'get'], workingDirectory: toolDir, environment: environment);
    if (g.exitCode != 0) throw CliException('dart pub get in $toolDir failed:\n${g.stdout}\n${g.stderr}');
  }
  final r = await Process.run(
    dartBin,
    ['run', p.join(toolDir, 'bin', 'ota_redirect.dart'), ...args],
    workingDirectory: toolDir,
    environment: environment,
  );
  if (r.exitCode != 0) {
    throw CliException('ota_redirect ${args.first} failed (exit ${r.exitCode}):\n${r.stdout}\n${r.stderr}');
  }
  return '${r.stdout}';
}

/// The private classes, mixins and enums the instrumented app exposes to patches (manifest
/// `private_types`), for the dynamic interface. Older manifests have none.
List<({String library, String className})> redirectPrivateClasses(String manifestPath) {
  final Object? j;
  try {
    j = jsonDecode(File(manifestPath).readAsStringSync());
  } on Object catch (e) {
    throw CliException('Cannot read the redirect manifest $manifestPath: $e');
  }
  final list = j is Map ? j['private_types'] : null;
  if (list == null) return const [];
  if (list is! List) throw CliException('$manifestPath: private_types is not a list.');
  return [
    for (final e in list)
      if (e is Map && e['library'] is String && e['class'] is String)
        (library: e['library'] as String, className: e['class'] as String)
      else
        throw CliException('$manifestPath: invalid private_types entry $e.'),
  ];
}

/// Paths of the redirect baseline of one release (`<release>/redirect/`).
class RedirectBaseline {
  RedirectBaseline(String releaseDir) : dir = p.join(releaseDir, redirectBaselineDir);
  final String dir;

  /// The app's source as it was built, BEFORE instrumentation (what patches diff against).
  String get source => p.join(dir, 'source');

  /// The app's source as it was compiled into the store build, AFTER instrumentation (what the
  /// patch guard resolves `package:<app>/` against: patches use its hidden slots and accessors).
  String get instrumented => p.join(dir, 'instrumented');

  /// Slot manifest of the store build (written by `ota_redirect instrument`).
  String get manifest => p.join(dir, 'ota_manifest.json');

  void check() {
    for (final f in [p.join(source, 'lib'), p.join(instrumented, 'lib'), manifest]) {
      if (FileSystemEntity.typeSync(f) == FileSystemEntityType.notFound) {
        throw CliException(
          'The redirect baseline in $dir is incomplete (${p.relative(f, from: dir)} is missing). '
          'Patches for this release cannot be built.',
        );
      }
    }
  }
}

/// The `name:` of a pubspec.yaml.
String pubspecName(String pubspecPath) {
  final m = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(File(pubspecPath).readAsStringSync());
  if (m == null) throw CliException('$pubspecPath has no name.');
  return m.group(1)!;
}

/// Saves what later redirect patches diff against: the app's source as it was built (before the
/// build copy was instrumented), the instrumented source, and the slot manifest of the store build.
///
/// In both copies the app package points at the copy itself; its dependencies keep pointing at
/// their real folders (the redirect engine patches the app package; dependencies need a store
/// release).
void saveRedirectBaseline({required String projectDir, required String instrumentedApp, required String releaseDir}) {
  final base = RedirectBaseline(releaseDir);
  if (Directory(base.dir).existsSync()) Directory(base.dir).deleteSync(recursive: true);
  final appName = pubspecName(p.join(projectDir, 'pubspec.yaml'));
  final config = p.join(projectDir, '.dart_tool', 'package_config.json');
  for (final (from, to) in [(projectDir, base.source), (instrumentedApp, base.instrumented)]) {
    _copyDir(Directory(p.join(from, 'lib')), Directory(p.join(to, 'lib')));
    File(p.join(from, 'pubspec.yaml')).copySync(p.join(to, 'pubspec.yaml'));
    _writeSelfConfig(config, appName, p.join(to, '.dart_tool', 'package_config.json'));
  }
  File(p.join(instrumentedApp, 'ota_manifest.json')).copySync(base.manifest);
}

/// Copies the package config [from] to [to]: package [appName] becomes the folder of [to],
/// every other relative root is made absolute.
void _writeSelfConfig(String from, String appName, String to) {
  final dotDartTool = File(from).absolute.parent.uri;
  final cfg = jsonDecode(File(from).readAsStringSync()) as Map<String, Object?>;
  for (final pkg in (cfg['packages']! as List).cast<Map<String, Object?>>()) {
    if (pkg['name'] == appName) {
      pkg['rootUri'] = '../';
      continue;
    }
    final root = pkg['rootUri']! as String;
    if (!root.contains(':')) pkg['rootUri'] = dotDartTool.resolve(root).toString();
  }
  File(to)
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg));
}

/// What the redirect engine cannot patch, from the release snapshot [diff] (the same source
/// hashes the feature engine uses). The engine patches the Dart code in `lib/` of the app package
/// [appName]; everything else the store build was made from must be unchanged. Returns
/// (refusals, notes).
(List<String>, List<String>) redirectRefusals(SnapshotDiff diff, String appName, Set<String> hostPackages) {
  const store = 'needs a new store release';
  final refusals = <String>[];
  final notes = <String>[];
  if (diff.lockChanged) {
    refusals.add(
      'pubspec.lock changed since the release: the store build was made with other dependency versions '
      '($store). Restore the lock file of the release, or make a new store release.',
    );
  }
  for (final c in diff.changed.toList()..sort((a, b) => a.name.compareTo(b.name))) {
    final n = c.name;
    if (c.added || c.removed) {
      refusals.add('$n was ${c.added ? 'added' : 'removed'} since the release ($store).');
      continue;
    }
    if (n != appName) {
      refusals.add(
        '$n changed (${c.describe()}). The redirect engine patches only the app package $appName; '
        'other packages are compiled into the store build as they were ($store).',
      );
      continue;
    }
    if (c.nativeChanged) refusals.add('$n: native code changed; only Dart code can be patched ($store).');
    if (c.otherFilesChanged) {
      refusals.add('$n: files outside lib/ changed (assets, fonts, ...); patches carry no assets yet ($store).');
    }
    if (c.flutterSectionChanged) {
      refusals.add('$n: the `flutter:` section of pubspec.yaml changed (assets, fonts or plugin) ($store).');
    }
    if (c.environmentChanged) refusals.add('$n: the `environment:` of pubspec.yaml changed ($store).');
    final missing = c.addedDependencies.where((d) => !hostPackages.contains(d)).toList();
    if (missing.isNotEmpty) {
      refusals.add('$n: new dependencies ${missing.join(', ')} are not part of the store build ($store).');
    }
    if (c.changedDependencies.isNotEmpty || c.removedDependencies.isNotEmpty) {
      notes.add('$n: dependency declarations changed; the patch still uses the versions of the store build.');
    }
  }
  return (refusals, notes);
}

/// Result of `ota_redirect patch`: the generated module package and what the tool decided.
class RedirectPatchSource {
  RedirectPatchSource(this.packageDir, this.report);
  final String packageDir;

  /// `ota_patch_report.json`: metrics (level, changed lines, interpreted functions) and the
  /// decisions (patched, initializers, repointed, side_fields, added, copied, refused, dropped,
  /// notes).
  final Map<String, Object?> report;

  Map<String, Object?> get metrics => ((report['metrics'] as Map?) ?? const {}).cast<String, Object?>();
  int get level => (metrics['level'] as num?)?.toInt() ?? -1;

  List<String> list(String key) => ((report[key] as List?) ?? const []).map((e) => '$e').toList();

  /// Reasons the change cannot ship as a patch (each needs a store release or a code change).
  List<String> get refused => list('refused');

  /// True when no file of the app package changed since the store release.
  bool get isEmpty => (metrics['files_changed'] as num?) == 0;
}

/// Runs `ota_redirect patch` (baseline source, project, [outDir], `--module` [moduleName],
/// `--manifest` of the baseline) and reads its report.
Future<RedirectPatchSource> generateRedirectPatch({
  required String dartBin,
  required String toolDir,
  required RedirectBaseline baseline,
  required String projectDir,
  required String outDir,
  required String moduleName,
  required Map<String, String> environment,
  void Function(String)? log,
}) async {
  final out = Directory(outDir);
  if (out.existsSync()) out.deleteSync(recursive: true);
  final stdout = await runRedirectTool(
    dartBin: dartBin,
    toolDir: toolDir,
    args: ['patch', baseline.source, projectDir, outDir, '--module', moduleName, '--manifest', baseline.manifest],
    environment: environment,
  );
  for (final l in stdout.trim().split('\n')) {
    if (l.trim().isNotEmpty) log?.call('  $l');
  }
  final f = File(p.join(outDir, 'ota_patch_report.json'));
  if (!f.existsSync() || !File(p.join(outDir, 'lib', 'entry.dart')).existsSync()) {
    throw CliException('ota_redirect patch wrote no module package in $outDir.');
  }
  return RedirectPatchSource(outDir, jsonDecode(f.readAsStringSync()) as Map<String, Object?>);
}

void _copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: from.path);
    if (e is Directory) {
      Directory(p.join(to.path, rel)).createSync(recursive: true);
    } else if (e is File) {
      final dest = File(p.join(to.path, rel));
      dest.parent.createSync(recursive: true);
      e.copySync(dest.path);
    }
  }
}
