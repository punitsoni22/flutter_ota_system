// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Several Flutter versions side by side: automatic toolchain choice, Android build tool minimums,
// patches built with the release's own toolchain, and `toolchain clean --unused` keeping toolchains
// that local store releases still need.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/doctor/android_build_versions.dart';
import 'package:flutter_ota_cli/src/patch/commands.dart' show releaseToolchainLock;
import 'package:flutter_ota_cli/src/toolchain/selection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// Writes the Android build files of a Flutter app with the given tool versions.
void writeAndroid(String dir, {required String gradle, required String agp, required String kgp}) {
  File(p.join(dir, 'android', 'gradle', 'wrapper', 'gradle-wrapper.properties'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('distributionUrl=https\\://services.gradle.org/distributions/gradle-$gradle-all.zip\n');
  File(p.join(dir, 'android', 'settings.gradle.kts')).writeAsStringSync('''
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "$agp" apply false
    id("org.jetbrains.kotlin.android") version "$kgp" apply false
}
''');
}

/// A local store release record naming [toolchain] (only the fields the commands under test read).
void writeRelease(String projectDir, String releaseId, {required String toolchain, required String toolchainId}) {
  File(p.join(projectDir, '.flutter_ota', 'releases', releaseId, 'release.json'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({'format': 1, 'release_id': releaseId, 'toolchain': toolchain, 'toolchain_id': toolchainId}),
    );
}

void main() {
  group('dartSatisfies', () {
    test('caret, ranges, exact and any', () {
      expect(dartSatisfies('^3.12.2', '3.13.7'), isTrue);
      expect(dartSatisfies('^3.12.2', '3.14.0'), isTrue);
      expect(dartSatisfies('^3.14.0', '3.13.7'), isFalse);
      expect(dartSatisfies('^3.14.0', '4.0.0'), isFalse);
      expect(dartSatisfies('">=3.8.0 <4.0.0"', '3.14.0'), isTrue);
      expect(dartSatisfies('>=3.8.0 <3.14.0', '3.14.0'), isFalse);
      expect(dartSatisfies('3.13.7', '3.13.7'), isTrue);
      expect(dartSatisfies('3.13.7', '3.14.0'), isFalse);
      expect(dartSatisfies('any', '3.14.0'), isTrue);
    });
  });

  group('Android build versions', () {
    late Directory d;
    setUp(() => d = Directory.systemTemp.createTempSync('flutter_ota_android'));
    tearDown(() => d.deleteSync(recursive: true));

    test('reads the wrapper and both plugins; compares numerically', () {
      writeAndroid(d.path, gradle: '9.1.0', agp: '9.0.1', kgp: '2.3.20');
      final v = AndroidBuildVersions.read(d.path);
      expect([v.gradle, v.agp, v.kgp], ['9.1.0', '9.0.1', '2.3.20']);
      final problems = v.problemsAgainst(minimumsFor('3.50.0')!);
      expect(problems, [
        'Gradle 9.1.0 < 9.3.1',
        'Android Gradle plugin 9.0.1 < 9.1.1',
        'Kotlin Gradle plugin 2.3.20 < 2.4.10',
      ]);
      expect(compareVersions('9.10.0', '9.3.1'), 1);
      expect(minimumsFor('3.47.9'), isNull);
    });

    test('a 3.50-level project has no problems', () {
      writeAndroid(d.path, gradle: '9.5.0', agp: '9.3.1', kgp: '2.4.20');
      expect(AndroidBuildVersions.read(d.path).problemsAgainst(minimumsFor('3.50.0')!), isEmpty);
    });
  });

  group('with a 3.47.9 and a 3.50.0 toolchain in the index', () {
    late Fixture f;
    late Map<String, Object?> a;
    late Map<String, Object?> b;
    setUp(() async {
      f = await Fixture.create();
      a = await f.makeToolchain(n: 1);
      b = await f.makeToolchain(n: 2, flutter: '3.50.0');
      f.writeIndex([a, b]);
      await f.configure();
      await f.run(['init', '--app-id', '3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f']);
    });
    tearDown(() => f.dispose());

    String pinned() => Lockfile.readIn(f.project)!.toolchain;

    test('a project with old Android build tools gets 3.47.9, and is told why', () async {
      writeAndroid(f.project, gradle: '8.14', agp: '8.11.1', kgp: '2.2.20');
      expect(await f.run(['toolchain', 'install']), 0, reason: f.output);
      expect(pinned(), 'flutter-3.47.9-ota.1');
      expect(f.output, contains('Skipping flutter-3.50.0-ota.2: needs newer Android build tools'));
    });

    test('a 3.50-level project gets 3.50.0', () async {
      writeAndroid(f.project, gradle: '9.5.0', agp: '9.3.1', kgp: '2.4.20');
      expect(await f.run(['toolchain', 'install']), 0, reason: f.output);
      expect(pinned(), 'flutter-3.50.0-ota.2');
    });

    test('upgrade warns when the project is below the target minimums', () async {
      writeAndroid(f.project, gradle: '8.14', agp: '8.11.1', kgp: '2.2.20');
      expect(await f.run(['toolchain', 'install']), 0, reason: f.output);
      expect(await f.run(['upgrade', '--yes', '--to', 'flutter-3.50.0-ota.2']), 0, reason: f.output);
      expect(f.output, contains('Flutter 3.50.0 refuses to build this project until you raise Gradle 8.14 < 9.3.1'));
    });

    test('clean --unused keeps a toolchain that a local store release still needs', () async {
      writeAndroid(f.project, gradle: '8.14', agp: '8.11.1', kgp: '2.2.20');
      expect(await f.run(['toolchain', 'install']), 0, reason: f.output); // pins 3.47.9
      writeRelease(f.project, 'r1', toolchain: 'flutter-3.47.9-ota.1', toolchainId: a['toolchain_id']! as String);
      writeAndroid(f.project, gradle: '9.5.0', agp: '9.3.1', kgp: '2.4.20');
      expect(await f.run(['upgrade', '--yes']), 0, reason: f.output); // now pins 3.50
      expect(pinned(), 'flutter-3.50.0-ota.2');
      expect(await f.run(['toolchain', 'clean', '--unused', '--yes']), 0, reason: f.output);
      expect(Directory(p.join(f.cacheRoot, 'toolchains', 'flutter-3.47.9-ota.1')).existsSync(), isTrue);
      expect(Directory(p.join(f.cacheRoot, 'toolchains', 'flutter-3.50.0-ota.2')).existsSync(), isTrue);
    });

    test("a release's own toolchain: installed, re-installed from the index, refused on an id mismatch", () async {
      writeAndroid(f.project, gradle: '8.14', agp: '8.11.1', kgp: '2.2.20');
      expect(await f.run(['toolchain', 'install']), 0, reason: f.output); // 3.47.9 installed
      final m = ToolchainManager(f.context());
      final idA = a['toolchain_id']! as String;

      final lock = await releaseToolchainLock(m, releaseId: 'r1', toolchain: 'flutter-3.47.9-ota.1', toolchainId: idA);
      expect([lock.toolchain, lock.toolchainId, lock.flutter], ['flutter-3.47.9-ota.1', idA, '3.47.9']);
      expect((await m.resolve(lock)).toolchainId, idA);

      Directory(p.join(f.cacheRoot, 'toolchains', 'flutter-3.47.9-ota.1')).deleteSync(recursive: true);
      final again = await releaseToolchainLock(m, releaseId: 'r1', toolchain: 'flutter-3.47.9-ota.1', toolchainId: idA);
      expect((await m.resolve(again)).toolchainId, idA);

      expect(
        () => releaseToolchainLock(m, releaseId: 'r1', toolchain: 'flutter-3.47.9-ota.1', toolchainId: 'f' * 64),
        throwsA(
          isA<CliException>().having((e) => e.message, 'message', contains('not in the verified toolchain index')),
        ),
      );
    });
  });
}
