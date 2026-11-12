// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Fixture f;
  late Map<String, Object?> a;
  late Map<String, Object?> b;
  setUp(() async {
    f = await Fixture.create();
    a = await f.makeToolchain(n: 1);
    f.writeIndex([a], serial: 1);
    await f.configure();
    await f.run(['init', '--app-id', '3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f']);
    expect(await f.run(['toolchain', 'install']), 0, reason: f.output);
    b = await f.makeToolchain(n: 2, id: 'flutter-3.47.9-ota.2');
    f.writeIndex([a, b], serial: 2);
  });
  tearDown(() => f.dispose());

  String pinned() => Lockfile.readIn(f.project)!.toolchain;
  String lockText() => File(p.join(f.project, lockFileName)).readAsStringSync();

  test('answering no leaves the lock unchanged', () async {
    final before = lockText();
    f.answers = ['n'];
    expect(await f.run(['upgrade']), 1);
    expect(f.prompts.single, contains('update flutter_ota.lock'));
    expect(lockText(), before);
    expect(Directory(p.join(f.cacheRoot, 'toolchains', 'flutter-3.47.9-ota.2')).existsSync(), isFalse);
  });

  test('no terminal and no --yes: refuses, never silent', () async {
    final before = lockText();
    expect(await f.run(['upgrade']), 1);
    expect(f.err.toString(), contains('--yes'));
    expect(lockText(), before);
  });

  test('answering yes installs and rewrites the lock', () async {
    f.answers = ['y'];
    expect(await f.run(['upgrade']), 0, reason: f.output);
    expect(pinned(), 'flutter-3.47.9-ota.2');
    expect(Lockfile.readIn(f.project)!.toolchainId, b['toolchain_id']);
  });

  test('--yes for CI, and --to selects a specific toolchain', () async {
    expect(await f.run(['upgrade', '--yes']), 0, reason: f.output);
    expect(pinned(), 'flutter-3.47.9-ota.2');
    expect(await f.run(['upgrade', '--yes', '--to', 'flutter-3.47.9-ota.1']), 0);
    expect(pinned(), 'flutter-3.47.9-ota.1');
    expect(f.prompts, isEmpty);
  });

  test('toolchain install of another id in a pinned project is refused', () async {
    expect(await f.run(['toolchain', 'install', 'flutter-3.47.9-ota.2']), 1);
    expect(f.err.toString(), contains('flutter_ota upgrade --to'));
    expect(pinned(), 'flutter-3.47.9-ota.1');
  });
}
