// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/owner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Fixture f;
  setUp(() async => f = await Fixture.create());
  tearDown(() => f.dispose());

  const uuid = '3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f';

  Future<Lockfile> installInProject() async {
    await f.run(['init', '--app-id', uuid]);
    final code = await f.run(['toolchain', 'install']);
    expect(code, 0, reason: f.output);
    return Lockfile.readIn(f.project)!;
  }

  test('install pins the toolchain, applies the overlay and resolves a build environment', () async {
    final entry = await f.makeToolchain();
    f.writeIndex([entry]);
    await f.configure();
    final lock = await installInProject();
    expect(lock.toolchain, 'flutter-3.47.9-ota.1');
    expect(lock.toolchainId, entry['toolchain_id']);
    final lockText = File(p.join(f.project, lockFileName)).readAsStringSync();
    expect(lockText, contains('format: 1'));
    expect(lockText, contains('engine: "$engine"'));
    expect(lockText, contains('dart_revision: "$dartRev"'));

    final m = ToolchainManager(f.context());
    final r = await m.resolve(lock);
    expect(File(r.genSnapshot).readAsStringSync(), 'OTA gen_snapshot 1');
    expect(FileStat.statSync(r.genSnapshot).mode & 0x49, 0x49); // executable
    expect(r.buildEnvironment['FLUTTER_STORAGE_BASE_URL'], 'file://${r.mirrorDir}');
    expect(r.buildEnvironment['GRADLE_USER_HOME'], r.gradleHome);
    expect(r.flutterBin, startsWith(f.cacheRoot));
    for (final m in mirrorFilesFor(engine)) {
      expect(File(p.join(r.root, m)).existsSync(), isTrue, reason: m);
    }
    for (final t in r.toolSnapshotPaths.values) {
      expect(File(t).existsSync(), isTrue);
    }
    // doctor passes; list marks the pin.
    f.out.clear();
    expect(await f.run(['toolchain', 'doctor']), 0, reason: f.output);
    expect(f.out.toString(), contains('[ok] overlay applied'));
    f.out.clear();
    expect(await f.run(['toolchain', 'list']), 0);
    expect(f.out.toString(), contains('* flutter-3.47.9-ota.1'));
    // Second install is a no-op.
    expect(await f.run(['toolchain', 'install']), 0);
    expect(f.err.toString(), contains('already installed'));
  });

  test('missing toolchain: clear error, never a fallback to another Flutter', () async {
    final entry = await f.makeToolchain();
    final lock = Lockfile(
      toolchain: entry['id'] as String,
      toolchainId: entry['toolchain_id'] as String,
      flutter: '3.47.9',
      dart: '3.13.7',
      engine: engine,
      dartRevision: dartRev,
    );
    final m = ToolchainManager(f.context());
    await expectLater(
      m.resolve(lock),
      throwsA(isA<ToolchainUnavailableException>().having((e) => e.message, 'message', contains('never falls back'))),
    );
  });

  test('a modified installed file fails resolve and doctor; install --force repairs it', () async {
    f.writeIndex([await f.makeToolchain()]);
    await f.configure();
    final lock = await installInProject();
    final m = ToolchainManager(f.context());
    final r = await m.resolve(lock);
    File(r.genSnapshot).writeAsStringSync('STOCK gen_snapshot'); // someone swapped in the stock one
    await expectLater(m.resolve(lock), throwsA(isA<ToolchainUnavailableException>()));
    f.out.clear();
    expect(await f.run(['toolchain', 'doctor']), 1);
    expect(f.out.toString(), contains('[x] overlay applied'));
    expect(f.out.toString(), contains('[x] file hashes'));
    expect(await f.run(['toolchain', 'install', '--force']), 0, reason: f.output);
    await m.resolve(lock);
  });

  test('SHA-256 mismatch: refused, partial file deleted, nothing installed', () async {
    final entry = await f.makeToolchain();
    final ov = (entry['artifacts'] as Map)['overlay'] as Map<String, Object?>;
    ov['sha256'] = '0' * 64;
    f.writeIndex([entry]);
    await f.configure();
    await f.run(['init', '--app-id', uuid]);
    expect(await f.run(['toolchain', 'install']), 1);
    expect(f.err.toString(), contains('SHA-256 mismatch'));
    expect(Directory(p.join(f.cacheRoot, 'downloads')).listSync().where((e) => e.path.endsWith('.part')), isEmpty);
    expect(Directory(p.join(f.cacheRoot, 'toolchains', entry['id'] as String)).existsSync(), isFalse);
    expect(File(p.join(f.project, lockFileName)).existsSync(), isFalse);
  });

  test('interrupted file:// download resumes from the partial file', () async {
    final entry = await f.makeToolchain();
    f.writeIndex([entry]);
    await f.configure();
    final sdk = (entry['artifacts'] as Map)['flutter_sdk'] as Map<String, Object?>;
    final src = File(p.join(f.mirror, sdk['url'] as String)).readAsBytesSync();
    final part = File(p.join(f.cacheRoot, 'downloads', '${sdk['sha256']}.part'))..createSync(recursive: true);
    part.writeAsBytesSync(src.sublist(0, src.length ~/ 2));
    await installInProject();
    expect(f.err.toString(), contains('Resuming Flutter 3.47.9 SDK'));
  });

  test('a corrupted partial file is detected after resume and downloaded again', () async {
    final entry = await f.makeToolchain();
    f.writeIndex([entry]);
    await f.configure();
    final sdk = (entry['artifacts'] as Map)['flutter_sdk'] as Map<String, Object?>;
    final part = File(p.join(f.cacheRoot, 'downloads', '${sdk['sha256']}.part'))..createSync(recursive: true);
    part.writeAsBytesSync(List.filled(100, 7));
    await installInProject();
    expect(f.err.toString(), contains('did not verify; downloading it again'));
  });

  test('a corrupted cached archive is re-downloaded', () async {
    final entry = await f.makeToolchain();
    f.writeIndex([entry]);
    await f.configure();
    final sdk = (entry['artifacts'] as Map)['flutter_sdk'] as Map<String, Object?>;
    final cached = File(p.join(f.cacheRoot, 'downloads', sdk['sha256'] as String))..createSync(recursive: true);
    cached.writeAsBytesSync(List.filled(sdk['size'] as int, 1));
    await installInProject();
    expect(f.err.toString(), contains('Cached Flutter 3.47.9 SDK is corrupted'));
  });

  test('an archive that is not a valid tar (but matches its index hash) is refused and deleted', () async {
    final entry = await f.makeToolchain();
    final junk = File(p.join(f.mirror, 'junk.tar.gz'))..writeAsStringSync('this is not an archive');
    (entry['artifacts'] as Map)['flutter_sdk'] = f.artifact(junk.path, root: 'flutter');
    f.writeIndex([entry]);
    await f.configure();
    await f.run(['init', '--app-id', uuid]);
    expect(await f.run(['toolchain', 'install']), 1);
    expect(f.err.toString(), contains('Could not extract'));
    final sha = ((entry['artifacts'] as Map)['flutter_sdk'] as Map)['sha256'] as String;
    expect(File(p.join(f.cacheRoot, 'downloads', sha)).existsSync(), isFalse);
    // No temp directories are left behind.
    expect(Directory(p.join(f.cacheRoot, 'toolchains')).listSync(), isEmpty);
  });

  test('leftovers of a killed install and a stale lock are recovered', () async {
    final entry = await f.makeToolchain();
    f.writeIndex([entry]);
    await f.configure();
    const deadPid = 2147480000; // above any Linux pid_max
    final stale = Directory(p.join(f.cacheRoot, 'toolchains', '.tmp-${entry['id']}-$deadPid-1'))
      ..createSync(recursive: true);
    File(p.join(stale.path, 'half')).writeAsStringSync('x');
    File(p.join(f.cacheRoot, 'locks', '${entry['id']}.lock'))
      ..createSync(recursive: true)
      ..writeAsStringSync('$deadPid\n');
    // A toolchain dir without install.json (crash after a rename by an older version).
    Directory(p.join(f.cacheRoot, 'toolchains', entry['id'] as String)).createSync();
    await installInProject();
    expect(stale.existsSync(), isFalse);
    expect(File(p.join(f.cacheRoot, 'locks', '${entry['id']}.lock')).existsSync(), isFalse);
  });

  test('lock contention: a live install holder blocks a second install', () async {
    final entry = await f.makeToolchain();
    f.writeIndex([entry]);
    await f.configure();
    final holder = await Process.start('sleep', ['30']);
    try {
      File(p.join(f.cacheRoot, 'locks', '${entry['id']}.lock'))
        ..createSync(recursive: true)
        ..writeAsStringSync('${holder.pid}\n');
      await f.run(['init', '--app-id', uuid]);
      expect(await f.run(['toolchain', 'install']), 1);
      expect(f.err.toString(), contains('pid ${holder.pid}'));
      expect(Directory(p.join(f.cacheRoot, 'toolchains', entry['id'] as String)).existsSync(), isFalse);
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  });

  test('disk-space refusal happens before any download', () async {
    f.writeIndex([await f.makeToolchain()]);
    await f.configure();
    f.freeBytes = 1024 * 1024;
    await f.run(['init', '--app-id', uuid]);
    expect(await f.run(['toolchain', 'install']), 1);
    expect(f.err.toString(), contains('Not enough disk space'));
    final dl = Directory(p.join(f.cacheRoot, 'downloads'));
    expect(!dl.existsSync() || dl.listSync().isEmpty, isTrue);
  });

  test('a stock SDK from another engine is refused', () async {
    final entry = await f.makeToolchain();
    final otherSdk = await f.makeSdkArchive(p.join(f.dir, 'lab1'), engineVersion: 'deadbeef' * 5);
    (entry['artifacts'] as Map)['flutter_sdk'] = f.artifact(otherSdk, root: 'flutter');
    f.writeIndex([entry]);
    await f.configure();
    await f.run(['init', '--app-id', uuid]);
    expect(await f.run(['toolchain', 'install']), 1);
    expect(f.err.toString(), contains('not built from engine'));
  });

  test('an older index serial is refused (rollback protection)', () async {
    final entry = await f.makeToolchain();
    f.writeIndex([entry], serial: 5);
    await f.configure();
    expect(await f.run(['toolchain', 'list']), 0, reason: f.output);
    f.writeIndex([entry], serial: 4);
    expect(await f.run(['toolchain', 'list']), 1);
    expect(f.err.toString(), contains('older than one already seen'));
  });

  test('an index signed by an untrusted key is refused by the CLI', () async {
    f.writeIndex([await f.makeToolchain()], signer: Es256KeyPair.generate(), signerId: 'rogue');
    await f.configure();
    expect(await f.run(['toolchain', 'install', 'flutter-3.47.9-ota.1']), 1);
    expect(f.err.toString(), contains('unknown key'));
  });

  test('clean removes downloads; --unused keeps pinned toolchains', () async {
    final a = await f.makeToolchain(n: 1);
    final b = await f.makeToolchain(n: 2, id: 'flutter-3.47.9-ota.2');
    f.writeIndex([a, b]);
    await f.configure();
    await installInProject(); // pins ota.2 (the newest)
    final outside = Directory(p.join(f.dir, 'elsewhere'))..createSync();
    expect(await f.run(['toolchain', 'install', 'flutter-3.47.9-ota.1'], cwd: outside.path), 0, reason: f.output);
    expect(await f.run(['toolchain', 'clean']), 0);
    expect(Directory(p.join(f.cacheRoot, 'downloads')).listSync(), isEmpty);
    expect(await f.run(['toolchain', 'clean', '--unused', '--yes']), 0);
    expect(Directory(p.join(f.cacheRoot, 'toolchains', 'flutter-3.47.9-ota.1')).existsSync(), isFalse);
    expect(Directory(p.join(f.cacheRoot, 'toolchains', 'flutter-3.47.9-ota.2')).existsSync(), isTrue);
  });

  test('the overlay archive is reproducible', () async {
    final l = await f.makeLab();
    Future<String> build(String out) async => (await buildOverlay(
      labDir: l,
      outFile: p.join(f.dir, out),
      toolchainName: 't',
      engineCommit: engine,
      flutterVersion: '3.47.9',
      notices: {'N': p.join(l, 'notice.txt')},
    )).sha256;
    final first = await build('a.tar.gz');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await build('b.tar.gz'), first);
  });
}
