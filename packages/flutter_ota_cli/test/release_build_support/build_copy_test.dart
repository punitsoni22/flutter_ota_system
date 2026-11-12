// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/src/build_support/build_copy.dart';
import 'package:flutter_ota_cli/src/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late String tmp;
  late String ws;
  late String app;
  late String dest;

  void write(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  bool exists(String rel) =>
      FileSystemEntity.typeSync(p.join(dest, rel), followLinks: false) != FileSystemEntityType.notFound;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flutter_ota_build_copy').resolveSymbolicLinksSync();
    ws = p.join(tmp, 'work');
    app = p.join(ws, 'demo_app');
    dest = p.join(tmp, 'canon', 'project');
    final featureB = p.join(ws, 'packages', 'feature_b');
    write(p.join(app, 'pubspec.yaml'), '''
name: demo_app
dependencies:
  dynamic_modules:
    path: .flutter_ota/packages/dynamic_modules
  feature_a:
    path: ../packages/feature_a
  feature_b:
    path: $featureB
  outside:
    path: /opt/somewhere/outside
dev_dependencies:
  feature_c: {path: "$ws/packages/feature_c"}
''');
    write(p.join(app, 'pubspec.lock'), '# lock\n');
    write(p.join(app, 'lib', 'main.dart'), '// main\n');
    write(p.join(app, 'lib', 'flutter_ota_main.g.dart'), '// generated entry\n');
    write(p.join(app, 'lib', 'flutter_ota_features.g.dart'), '// generated registry\n');
    write(p.join(app, 'lib', 'build', 'keep.dart'), '// a source folder named build\n');
    write(p.join(app, '.flutter_ota', 'packages', 'dynamic_modules', 'pubspec.yaml'), 'name: dynamic_modules\n');
    write(p.join(app, '.flutter_ota', 'release.json'), '{}\n');
    write(p.join(app, '.flutter_ota', 'releases', 'r1', 'link.dill'), 'baseline');
    write(p.join(app, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk'), 'old apk');
    write(p.join(app, '.dart_tool', 'flutter_build', 'dart_plugin_registrant.dart'), '// $tmp');
    write(p.join(app, '.flutter-plugins-dependencies'), '{"path": "$tmp"}');
    write(p.join(app, '.git', 'HEAD'), 'ref');
    write(p.join(app, 'ios', 'Runner', 'Info.plist'), 'plist');
    write(p.join(app, 'android', 'app', 'build.gradle.kts'), '// gradle');
    write(p.join(app, 'android', 'app', '.cxx', 'x'), 'native cache');
    write(p.join(app, 'android', 'local.properties'), 'sdk.dir=$tmp/Android');
    write(p.join(app, 'android', 'key.properties'), 'storeFile=../upload.jks');
    write(p.join(app, 'android', '.gradle', 'cache'), 'gradle');
    write(p.join(app, 'android', 'gradlew'), '#!/bin/sh\n');
    Process.runSync('chmod', ['0755', p.join(app, 'android', 'gradlew')]);
    for (final n in ['feature_a', 'feature_b', 'feature_c']) {
      write(p.join(ws, 'packages', n, 'pubspec.yaml'), 'name: $n\n');
      write(p.join(ws, 'packages', n, 'lib', '$n.dart'), '// $n\n');
      write(p.join(ws, 'packages', n, 'build', 'x'), 'build output');
      write(p.join(ws, 'packages', n, '.dart_tool', 'x'), 'cache');
    }
    write(p.join(ws, 'packages', 'feature_a', 'pubspec_overrides.yaml'), '''
dependency_overrides:
  feature_b:
    path: $featureB
''');
    Link(p.join(app, 'assets_link')).createSync(p.join(ws, 'packages', 'feature_a', 'lib'));
    Link(p.join(app, 'relative_link')).createSync('lib');
  });

  tearDown(() => Directory(tmp).deleteSync(recursive: true));

  BuildCopy make({Iterable<String> skip = const []}) =>
      BuildCopy.create(workspace: ws, app: app, dest: dest, skip: skip);

  test('copies sources and generated files, leaves out outputs, caches and baselines', () {
    final copy = make();
    expect(copy.root, dest);
    expect(copy.appDir, p.join(dest, 'demo_app'));
    for (final rel in [
      'demo_app/pubspec.yaml',
      'demo_app/pubspec.lock',
      'demo_app/lib/main.dart',
      'demo_app/lib/flutter_ota_main.g.dart',
      'demo_app/lib/flutter_ota_features.g.dart',
      'demo_app/lib/build/keep.dart',
      'demo_app/.flutter_ota/packages/dynamic_modules/pubspec.yaml',
      'demo_app/.flutter_ota/release.json',
      'demo_app/android/app/build.gradle.kts',
      'demo_app/android/key.properties',
      'demo_app/android/gradlew',
      'packages/feature_a/lib/feature_a.dart',
      'packages/feature_a/pubspec_overrides.yaml',
      'packages/feature_b/lib/feature_b.dart',
    ]) {
      expect(exists(rel), isTrue, reason: rel);
    }
    for (final rel in [
      'demo_app/build',
      'demo_app/.dart_tool',
      'demo_app/.flutter-plugins-dependencies',
      'demo_app/.git',
      'demo_app/ios',
      'demo_app/.flutter_ota/releases',
      'demo_app/android/local.properties',
      'demo_app/android/.gradle',
      'demo_app/android/app/.cxx',
      'packages/feature_a/build',
      'packages/feature_a/.dart_tool',
    ]) {
      expect(exists(rel), isFalse, reason: rel);
    }
    // gradlew stays executable.
    expect(File(p.join(dest, 'demo_app', 'android', 'gradlew')).statSync().mode & 0x40, isNonZero);
    // Links: absolute into the workspace -> into the copy; relative kept.
    expect(Link(p.join(dest, 'demo_app', 'assets_link')).targetSync(), p.join(dest, 'packages', 'feature_a', 'lib'));
    expect(Link(p.join(dest, 'demo_app', 'relative_link')).targetSync(), 'lib');
    // Nothing in the copy names the real workspace except files we did not rewrite on purpose.
    final leaks = Directory(dest)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.readAsStringSync().contains(ws))
        .map((f) => p.relative(f.path, from: dest))
        .toList();
    expect(leaks, isEmpty);
  });

  test('absolute path dependencies inside the workspace become relative; others are kept', () {
    make();
    final pubspec = File(p.join(dest, 'demo_app', 'pubspec.yaml')).readAsStringSync();
    expect(pubspec, contains("  feature_b:\n    path: '../packages/feature_b'\n"));
    expect(pubspec, contains("  feature_c: {path: '../packages/feature_c'}\n"));
    expect(pubspec, contains('    path: ../packages/feature_a\n'));
    expect(pubspec, contains('    path: .flutter_ota/packages/dynamic_modules\n'));
    expect(pubspec, contains('    path: /opt/somewhere/outside\n'));
    final overrides = File(p.join(dest, 'packages', 'feature_a', 'pubspec_overrides.yaml')).readAsStringSync();
    expect(overrides, contains("    path: '../feature_b'\n"));
    // The real project is untouched.
    expect(
      File(p.join(app, 'pubspec.yaml')).readAsStringSync(),
      contains('    path: ${p.join(ws, 'packages', 'feature_b')}\n'),
    );
  });

  test('rewritePathDependencies returns null when nothing changes', () {
    expect(
      rewritePathDependencies('name: x\ndependencies:\n  a:\n    path: ../a\n', realDir: app, realWorkspace: ws),
      isNull,
    );
    expect(rewritePathDependencies('not: [valid', realDir: app, realWorkspace: ws), isNull);
    expect(rewritePathDependencies('name: x\ndependencies:\n  a: ^1.0.0\n', realDir: app, realWorkspace: ws), isNull);
  });

  test('copyOutputBack puts the store file at the same place in the real project', () {
    final copy = make();
    final built = p.join(copy.appDir, 'build', 'app', 'outputs', 'bundle', 'release', 'app-release.aab');
    write(built, 'new aab');
    final back = copy.copyOutputBack(built);
    expect(back, p.join(app, 'build', 'app', 'outputs', 'bundle', 'release', 'app-release.aab'));
    expect(File(back).readAsStringSync(), 'new aab');
    // Other outputs of the copy are not copied back.
    write(p.join(copy.appDir, 'build', 'app', 'intermediates', 'x'), 'x');
    expect(Directory(p.join(app, 'build', 'app', 'intermediates')).existsSync(), isFalse);
    expect(() => copy.copyOutputBack(p.join(tmp, 'elsewhere.apk')), throwsA(isA<CliException>()));
  });

  test('replaces a stale copy; remove deletes it', () {
    write(p.join(dest, 'stale.txt'), 'old');
    make();
    expect(exists('stale.txt'), isFalse);
    BuildCopy.remove(dest);
    expect(Directory(dest).existsSync(), isFalse);
    BuildCopy.remove(dest); // no-op
  });

  test('skips given folders and a copy that lies inside the workspace; refuses a copy around it', () {
    write(p.join(ws, 'pub-cache', 'hosted', 'x'), 'pkg');
    final inner = p.join(ws, 'canon', 'project');
    var copy = BuildCopy.create(
      workspace: ws,
      app: app,
      dest: inner,
      skip: [p.join(ws, 'pub-cache'), p.join(ws, 'canon')],
    );
    expect(File(p.join(copy.appDir, 'lib', 'main.dart')).existsSync(), isTrue);
    expect(Directory(p.join(inner, 'pub-cache')).existsSync(), isFalse);
    expect(Directory(p.join(inner, 'canon')).existsSync(), isFalse);
    // Without the root in [skip], the copy itself is still never copied into itself.
    copy = BuildCopy.create(workspace: ws, app: app, dest: inner);
    expect(Directory(p.join(inner, 'canon', 'project')).existsSync(), isFalse);
    expect(() => BuildCopy.create(workspace: ws, app: app, dest: tmp), throwsA(isA<CliException>()));
    expect(() => BuildCopy.create(workspace: ws, app: tmp, dest: dest), throwsA(isA<CliException>()));
  });

  test('excludedFromBuildCopy', () {
    for (final rel in [
      'build',
      'ios',
      '.dart_tool',
      'a/.git',
      'android/.gradle/x',
      'android/local.properties',
      '.flutter_ota/releases/r/x',
    ]) {
      expect(excludedFromBuildCopy(rel), isTrue, reason: rel);
    }
    for (final rel in [
      'lib/build',
      'android/app/build.gradle',
      'lib/ios.dart',
      '.flutter_ota/packages/x',
      'android/key.properties',
    ]) {
      expect(excludedFromBuildCopy(rel), isFalse, reason: rel);
    }
  });
}
