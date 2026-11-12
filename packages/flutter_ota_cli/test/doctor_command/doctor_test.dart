// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../release_android/release_support.dart';

void main() {
  late ReleaseWorld w;
  setUp(() async => w = await ReleaseWorld.create());
  tearDown(() => w.dispose());

  test('all checks pass after keys init', () async {
    expect(await w.run(['keys', 'init']), 0, reason: w.output);
    w.out.clear();
    expect(await w.run(['doctor']), 0, reason: w.output);
    final o = w.out.toString();
    for (final name in [
      'flutter_ota.yaml: app_id $appId',
      'flutter app: demo_app',
      'android project',
      'SDK dependency: flutter_ota_system',
      '.gitignore: .flutter_ota/releases/ is ignored',
      'FlutterOta.initialize: called',
      'flutter_ota.lock: $toolchainName',
      'toolchain: installed and verified',
      'server URL: ${w.backend.url}',
      'admin key: FLUTTER_OTA_ADMIN_KEY is set',
      'server reachable',
      'app on server: slug $appSlug',
      'root keys: root-',
      'signer key: signer-',
    ]) {
      expect(o, contains('[ok] $name'), reason: name);
    }
    expect(o, contains('Ready for `flutter_ota release android`'));
    expect(File(w.globalMarker).existsSync(), isFalse);
    // Doctor only reads: no build ran.
    expect(w.flutterCalls(), isEmpty);
  });

  test('reports every missing piece with a fix', () async {
    File(p.join(w.project, 'lib', 'main.dart')).writeAsStringSync('void main() {}\n');
    File(p.join(w.project, '.gitignore')).writeAsStringSync('/build/\n');
    File(p.join(w.project, 'flutter_ota.lock')).deleteSync();
    expect(await w.run(['doctor'], drop: {'FLUTTER_OTA_ADMIN_KEY', 'FLUTTER_OTA_SERVER_URL'}), 1);
    final o = w.out.toString();
    expect(o, contains('[!]  FlutterOta.initialize: not found'));
    expect(o, contains('[!]  .gitignore: .flutter_ota/releases/ is not in .gitignore'));
    expect(o, contains('[x]  flutter_ota.lock: missing'));
    expect(o, contains('fix: flutter_ota toolchain install'));
    expect(o, contains('[x]  server URL: not set'));
    expect(o, contains('[x]  admin key: FLUTTER_OTA_ADMIN_KEY is not set'));
    expect(o, contains('Some checks failed'));
  });

  test('ignoring all of .flutter_ota/ is a warning (the loader package must be committed)', () async {
    File(p.join(w.project, '.gitignore')).writeAsStringSync('/.flutter_ota/\n');
    await w.run(['doctor']);
    expect(w.out.toString(), contains('[!]  .gitignore: all of .flutter_ota/ is ignored'));
    expect(w.out.toString(), contains('fix: ignore only `/.flutter_ota/releases/`'));
  });

  test('no keys yet, unknown app, unreachable server', () async {
    expect(await w.run(['doctor']), 1);
    expect(w.out.toString(), contains('[x]  root keys: This machine has no root key'));
    expect(w.out.toString(), contains('fix: flutter_ota keys init'));

    w.out.clear();
    w.backend.apps.clear();
    expect(await w.run(['doctor']), 1);
    expect(w.out.toString(), contains('[x]  app on server: The server ${w.backend.url} has no application'));

    w.out.clear();
    w.backend.healthy = false;
    expect(await w.run(['doctor']), 1);
    expect(w.out.toString(), contains('[x]  server reachable: HTTP 503'));
  });

  test('no flutter_ota.yaml / wrong yaml / tampered toolchain', () async {
    File(p.join(w.project, 'flutter_ota.yaml')).writeAsStringSync('app_id: com.example.app\n');
    expect(await w.run(['doctor']), 1);
    expect(w.out.toString(), contains('[x]  flutter_ota.yaml: "com.example.app" is not a valid app_id'));

    w.out.clear();
    File(p.join(w.project, 'flutter_ota.yaml')).deleteSync();
    expect(await w.run(['doctor']), 1);
    expect(w.out.toString(), contains('fix: flutter_ota init --app-id'));

    w.out.clear();
    File(p.join(w.project, 'flutter_ota.yaml')).writeAsStringSync('app_id: $appId\n');
    File(p.join(w.toolchainDir, 'toolchain.json')).writeAsStringSync('{}');
    expect(await w.run(['doctor']), 1);
    expect(w.out.toString(), contains('[x]  toolchain: The installed toolchain $toolchainName failed verification'));
  });
}
