// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/owner.dart';
import 'package:path/path.dart' as p;

import 'elf_fixture.dart';
import 'release_android/release_support.dart' show makeZip;

const engine = '89c39edfdfae2949f6806e4a315c0c08522238b7';
const dartRev = '416e33b0ffaef062a60ec966bb8c82ed2b83f128';
const keyId = 'test-toolchain-key';

/// A temporary world: fake lab, fixture archives, a file:// mirror with a signed index, and a
/// CLI context whose HOME, cache and config all live in the temp dir. Nothing touches the real
/// home directory, the real lab or any real Flutter SDK.
class Fixture {
  Fixture._(this.dir);

  final String dir;
  final out = StringBuffer();
  final err = StringBuffer();
  final key = Es256KeyPair.generate();
  final prompts = <String>[];
  List<String?> answers = [];
  int? freeBytes;

  String get lab => p.join(dir, 'lab');
  String get mirror => p.join(dir, 'mirror');
  String get project => p.join(dir, 'app');
  String get cacheRoot => p.join(dir, 'cache');
  String get configDir => p.join(dir, 'config');

  static Future<Fixture> create() async {
    final f = Fixture._(Directory.systemTemp.createTempSync('flutter_ota_cli_test').path);
    Directory(f.project).createSync(recursive: true);
    File(p.join(f.project, 'pubspec.yaml')).writeAsStringSync('name: app\n');
    return f;
  }

  void dispose() => Directory(dir).deleteSync(recursive: true);

  Map<String, String> env([Map<String, String> extra = const {}]) => {
    'HOME': p.join(dir, 'home'),
    'FLUTTER_OTA_CACHE': cacheRoot,
    'FLUTTER_OTA_CONFIG_DIR': configDir,
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    ...extra,
  };

  CliContext context({String? cwd, Map<String, String> extraEnv = const {}}) => CliContext(
    environment: env(extraEnv),
    workingDirectory: cwd ?? project,
    out: out,
    err: err,
    prompt: (q) {
      prompts.add(q);
      return answers.isEmpty ? null : answers.removeAt(0);
    },
    diskSpace: (_) async => freeBytes,
  );

  Future<int> run(List<String> args, {String? cwd, Map<String, String> extraEnv = const {}}) => runCli(
    args,
    context: context(cwd: cwd, extraEnv: extraEnv),
  );

  /// Trust the fixture key and point the CLI at the fixture mirror.
  Future<void> configure() async {
    final cfg = UserConfig.load(env());
    cfg.addToolchainKey(keyId, key.publicKeyBase64);
    cfg.set('toolchain-index-url', 'file://$mirror/index.json');
  }

  /// Creates the fake lab (same layout as ~/.cache/flutter-ota-lab) for toolchain [n].
  Future<String> makeLab({int n = 1, String flutter = '3.47.9'}) async {
    final l = p.join(dir, 'lab$n');
    void w(String rel, String content) {
      final f = File(p.join(l, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    w('flutter/bin/flutter', '#!/bin/sh\necho fake flutter\n');
    w('flutter/bin/internal/engine.version', '$engine\n');
    w('flutter/bin/cache/dart-sdk/bin/dart', 'fake dart');
    w('flutter/$genSnapshotSdkPath.stock', 'STOCK gen_snapshot');
    w('flutter/$genSnapshotSdkPath', 'OTA gen_snapshot $n');
    w('flutter/LICENSE', 'BSD flutter');
    for (final m in mirrorFilesFor(engine)) {
      if (m.contains('/arm64_v8a_release/') && m.endsWith('.jar')) {
        // The lab jar holds the stripped engine; the engine build dir the unstripped one (same build ID).
        final jar = File(p.join(l, m))..parent.createSync(recursive: true);
        jar.writeAsBytesSync(makeZip({'lib/arm64-v8a/libflutter.so': fakeElf(otaEngineBuildId)}));
        final lib = File(p.join(l, 'engine/engine/src/out/android_release_arm64/libflutter.so'))
          ..parent.createSync(recursive: true);
        lib.writeAsBytesSync(fakeElf(otaEngineBuildId, padding: 4096 + n));
        continue;
      }
      w(m, 'maven $m $n');
    }
    for (final t in toolSnapshots) {
      w('work/tools/$t.aot', 'snapshot $t $n');
    }
    final fields = {
      'flutter': flutter,
      'dart': '3.13.7',
      'engine': engine.substring(0, 8),
      'dart_revision': dartRev.substring(0, 8),
      'generator_sha256': sha256.convert(utf8.encode('gen $n')).toString(),
      'bytecode_format': 3,
    };
    w('work/toolchain.json', jsonEncode({...fields, 'id': computeToolchainId(fields)}));
    w('notice.txt', 'notice');
    return l;
  }

  /// Builds the stock SDK fixture archive from a lab (gen_snapshot = the stock one).
  Future<String> makeSdkArchive(String labDir, {String? engineVersion}) async {
    final stage = Directory(p.join(dir, 'sdk-stage-${DateTime.now().microsecondsSinceEpoch}'));
    final r = await Process.run('cp', ['-a', p.join(labDir, 'flutter'), stage.path]);
    if (r.exitCode != 0) throw StateError('cp: ${r.stderr}');
    final gs = File(p.join(stage.path, genSnapshotSdkPath));
    File('${gs.path}.stock').renameSync(gs.path);
    if (engineVersion != null) {
      File(p.join(stage.path, 'bin/internal/engine.version')).writeAsStringSync(engineVersion);
    }
    final parent = Directory(p.join(dir, 'sdk-parent-${DateTime.now().microsecondsSinceEpoch}'))..createSync();
    stage.renameSync(p.join(parent.path, 'flutter'));
    Directory(mirror).createSync(recursive: true);
    final out = p.join(mirror, 'flutter_sdk_${DateTime.now().microsecondsSinceEpoch}.tar.gz');
    final t = await Process.run('tar', ['-czf', out, '-C', parent.path, 'flutter']);
    if (t.exitCode != 0) throw StateError('tar: ${t.stderr}');
    parent.deleteSync(recursive: true);
    return out;
  }

  /// Builds a full toolchain (lab, sdk archive, overlay) and returns its index entry JSON.
  Future<Map<String, Object?>> makeToolchain({int n = 1, String? id, String flutter = '3.47.9'}) async {
    final l = await makeLab(n: n, flutter: flutter);
    final sdk = await makeSdkArchive(l);
    final name = id ?? 'flutter-$flutter-ota.$n';
    final ov = await buildOverlay(
      labDir: l,
      outFile: p.join(mirror, 'overlays', '$name.tar.gz'),
      toolchainName: name,
      engineCommit: engine,
      flutterVersion: flutter,
      notices: {'LICENSE.flutter': p.join(l, 'notice.txt')},
    );
    return indexEntry(
      id: name,
      toolchainId: ov.toolchainId,
      flutter: flutter,
      dart: '3.13.7',
      engine: engine,
      dartRevision: dartRev,
      sdk: artifact(sdk, root: 'flutter'),
      overlay: artifact(ov.path),
    );
  }

  Map<String, Object?> artifact(String path, {String? root}) => {
    'url': p.relative(path, from: mirror),
    'sha256': sha256.convert(File(path).readAsBytesSync()).toString(),
    'size': File(path).lengthSync(),
    'format': 'tar.gz',
    'root': ?root,
  };

  void writeIndex(List<Map<String, Object?>> entries, {int serial = 1, Es256KeyPair? signer, String? signerId}) {
    Directory(mirror).createSync(recursive: true);
    File(
      p.join(mirror, 'index.json'),
    ).writeAsBytesSync(signIndex({'serial': serial, 'toolchains': entries}, signerId ?? keyId, signer ?? key));
  }

  String get output => '$out$err';
}
