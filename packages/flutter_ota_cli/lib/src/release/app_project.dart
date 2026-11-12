// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../errors.dart';
import '../project/project.dart';

/// Name of the SDK package an OTA app must depend on.
const sdkPackageName = 'flutter_ota_system';

/// The CLI's own folder inside a project (release baselines; see docs/releasing-with-flutter-ota.md).
const otaWorkDirName = '.flutter_ota';

/// What `doctor` and `release` need to know about a Flutter app project.
class AppProject {
  AppProject._({
    required this.dir,
    required this.packageName,
    required this.version,
    required this.isFlutterApp,
    required this.hasAndroid,
    required this.dependsOnSdk,
    required this.mainCallsInitialize,
    required this.hasMain,
    required this.gitIgnoresWorkDir,
    required this.gitIgnoresWholeWorkDir,
  });

  /// Reads `pubspec.yaml`, `android/` and `lib/main.dart` of [dir]. Throws [CliException] when
  /// `pubspec.yaml` is missing or unreadable.
  factory AppProject.inspect(String dir) {
    final pubspec = File(p.join(dir, 'pubspec.yaml'));
    if (!pubspec.existsSync()) throw CliException('No pubspec.yaml in $dir. Run flutter_ota in your Flutter app.');
    final Object? y;
    try {
      y = loadYaml(pubspec.readAsStringSync());
    } on YamlException catch (e) {
      throw CliException('${pubspec.path} is not valid YAML: ${e.message}');
    }
    if (y is! YamlMap || y['name'] is! String) throw CliException('${pubspec.path} has no package name.');
    final deps = y['dependencies'];
    final flutterDep = deps is YamlMap ? deps['flutter'] : null;
    final isFlutter = flutterDep is YamlMap && flutterDep['sdk'] == 'flutter';
    final main = File(p.join(dir, 'lib', 'main.dart'));
    final mainText = main.existsSync() ? main.readAsStringSync() : '';
    final android = Directory(p.join(dir, 'android', 'app'));
    final hasGradle =
        File(p.join(android.path, 'build.gradle')).existsSync() ||
        File(p.join(android.path, 'build.gradle.kts')).existsSync();
    final gi = File(p.join(dir, '.gitignore'));
    final giLines = gi.existsSync() ? gi.readAsLinesSync().map((l) => l.trim()).toList() : const <String>[];
    final ignoresAll = giLines.any((l) => RegExp(r'^/?\.flutter_ota/?\*{0,2}$').hasMatch(l));
    final ignores = ignoresAll || giLines.any((l) => RegExp(r'^/?\.flutter_ota/releases/?\*{0,2}$').hasMatch(l));
    final version = y['version'];
    return AppProject._(
      dir: dir,
      packageName: y['name'] as String,
      version: version == null ? null : '$version',
      isFlutterApp: isFlutter,
      hasAndroid: hasGradle,
      dependsOnSdk: deps is YamlMap && deps.containsKey(sdkPackageName),
      mainCallsInitialize: RegExp(r'FlutterOta\s*\.\s*initialize\s*\(').hasMatch(mainText),
      hasMain: main.existsSync(),
      gitIgnoresWorkDir: ignores,
      gitIgnoresWholeWorkDir: ignoresAll,
    );
  }

  final String dir;
  final String packageName;

  /// `version:` from pubspec.yaml (for example `1.2.0+7`), or null.
  final String? version;
  final bool isFlutterApp;
  final bool hasAndroid;
  final bool dependsOnSdk;
  final bool mainCallsInitialize;
  final bool hasMain;

  /// `.flutter_ota/releases/` (large baselines) is git-ignored.
  final bool gitIgnoresWorkDir;

  /// All of `.flutter_ota/` is git-ignored, so the generated `.flutter_ota/packages/` (which
  /// pubspec.yaml points at) would not be committed.
  final bool gitIgnoresWholeWorkDir;

  String get workDir => p.join(dir, otaWorkDirName);
  String get releasesDir => p.join(workDir, 'releases');
}

/// Finds the project from [cwd] and reads its `app_id` (only key allowed in flutter_ota.yaml).
(String dir, String appId) requireProject(String cwd) {
  final dir = findProjectDir(cwd);
  if (dir == null) {
    throw CliException(
      'No $projectFileName found in $cwd or above.\n'
      'Run in your Flutter app:  flutter_ota init --app-id <server application UUID>',
    );
  }
  return (dir, readAppId(dir));
}

/// Splits a pubspec version `1.2.0+7` into name and number.
(String name, String? number) splitVersion(String version) {
  final i = version.indexOf('+');
  return i < 0 ? (version, null) : (version.substring(0, i), version.substring(i + 1));
}
