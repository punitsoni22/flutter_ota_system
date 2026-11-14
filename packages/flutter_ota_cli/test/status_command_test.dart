// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'ops_support.dart';
import 'patch_support.dart';

void main() {
  late OpsWorld w;
  tearDown(() => w.dispose());

  test('no patches on the server: says so', () async {
    w = await OpsWorld.create();
    expect(await w.run(['status']), 0, reason: w.output);
    final out = w.out.toString();
    expect(out, contains('App:      shop  (id $testAppId)'));
    expect(out, contains('Release:  $testReleaseId'));
    expect(out, contains('version 1.0.0, environment production, registered on the server'));
    expect(out, contains('Patches:  none on the server for this release yet.'));
    expect(out, contains('Devices:  no device has checked for updates yet (version 1.0.0).'));
    expect(w.backend.requests.every((r) => r.method == 'GET'), isTrue);
  });

  test('lists patches with status, channels and rollout, and the device summary', () async {
    w = await OpsWorld.create();
    w.backend.patches.addAll([
      serverPatch(1, 'rolled_back', channels: {'stable': 100}),
      serverPatch(2, 'published', channels: {'stable': 100, 'beta': 12.5}),
      serverPatch(3, 'draft'),
    ]);
    w.backend.devices.addAll([
      {'platform': 'android', 'release_version': '1.0.0', 'channel': 'stable', 'patch_number': 2, 'devices': 3},
      {'platform': 'android', 'release_version': '1.0.0', 'channel': 'stable', 'patch_number': null, 'devices': 1},
      {'platform': 'android', 'release_version': '0.9.0', 'channel': 'stable', 'patch_number': 5, 'devices': 7},
    ]);
    expect(await w.run(['status']), 0, reason: w.output);
    final out = w.out.toString();
    expect(out, contains('Patches (3):'));
    expect(out, matches(RegExp(r'1\s+rolled_back\s+dbc-v1\s+\(was\) stable 100%')));
    expect(out, matches(RegExp(r'2\s+published\s+dbc-v1\s+stable 100%, beta 12.5%')));
    expect(out, matches(RegExp(r'3\s+draft\s+dbc-v1\s+-')));
    expect(out, contains(serverPatch(2, 'published')['id'] as String));
    expect(out, contains('android, channel stable: patch 2 - 3 devices'));
    expect(out, contains('android, channel stable: store code (no patch) - 1 device'));
    // Other release versions are not mixed in.
    expect(out, isNot(contains('patch 5')));
  });

  test('--json prints machine-readable output', () async {
    w = await OpsWorld.create();
    w.backend.patches.add(serverPatch(1, 'published', channels: {'stable': 50}));
    w.backend.devices.add({
      'platform': 'android',
      'release_version': '1.0.0',
      'channel': 'stable',
      'patch_number': 1,
      'devices': 2,
    });
    expect(await w.run(['status', '--json']), 0, reason: w.output);
    final j = jsonDecode(w.out.toString()) as Map<String, Object?>;
    expect(j['server_url'], w.backend.url);
    expect(j['app'], {'id': testAppId, 'slug': opsSlug, 'name': 'Shop'});
    final release = j['release'] as Map<String, Object?>;
    expect(release['id'], testReleaseId);
    expect(release['version'], '1.0.0');
    expect(release['registered'], isTrue);
    final patches = (j['patches'] as List).cast<Map<String, Object?>>();
    expect(patches.single['number'], 1);
    expect(patches.single['status'], 'published');
    expect(patches.single['format'], 'dbc-v1');
    expect(patches.single['channels'], [
      {'channel': 'stable', 'rollout_percent': 50.0},
    ]);
    expect(j['patches_problem'], isNull);
    expect((j['devices'] as List).single, containsPair('devices', 2));
  });

  test('--json with no patches gives an empty list', () async {
    w = await OpsWorld.create();
    expect(await w.run(['status', '--json']), 0, reason: w.output);
    final j = jsonDecode(w.out.toString()) as Map<String, Object?>;
    expect(j['patches'], isEmpty);
    expect(j['devices'], isEmpty);
  });

  test('--release picks a release; an unknown local release is an error', () async {
    w = await OpsWorld.create();
    expect(await w.run(['status', '--release', testReleaseId]), 0, reason: w.output);
    expect(w.backend.requests.any((r) => r.path == '/v1/admin/releases/$testReleaseId/patches'), isTrue);
    expect(await w.run(['status', '--release', '11111111-1111-4111-8111-111111111111']), 1);
    expect(w.err.toString(), contains('There is no local release'));
  });

  test('without a local release it still shows the app', () async {
    w = await OpsWorld.create(withRelease: false);
    expect(await w.run(['status']), 0, reason: w.output);
    expect(w.out.toString(), contains('Release:  (none on this machine)'));
    expect(w.out.toString(), contains('flutter_ota release android'));
  });

  test('an unregistered release has no server patches', () async {
    w = await OpsWorld.create(registered: false);
    expect(await w.run(['status']), 0, reason: w.output);
    expect(w.out.toString(), contains('NOT registered on a server'));
    expect(w.out.toString(), contains('never registered on a server'));
    expect(w.backend.requests.any((r) => r.path.contains('/patches')), isFalse);
  });

  test('uses the server URL recorded with the release when none is configured', () async {
    w = await OpsWorld.create();
    final f = File(p.join(w.project, '.flutter_ota', 'releases', testReleaseId, 'release.json'));
    final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    (j['registered'] as Map)['server_url'] = w.backend.url;
    f.writeAsStringSync(jsonEncode(j));
    expect(await w.run(['status'], drop: {'FLUTTER_OTA_SERVER_URL'}), 0, reason: w.output);
    expect(w.out.toString(), contains('Server:   ${w.backend.url}'));
  });

  test('server errors are reported clearly', () async {
    w = await OpsWorld.create();
    w.backend.failPatchList = 500;
    expect(await w.run(['status']), 1);
    expect(w.err.toString(), contains('HTTP 500'));
    expect(w.err.toString(), contains('database is down'));
  });

  test('a release unknown to the server and a missing device summary are shown, not fatal', () async {
    w = await OpsWorld.create();
    w.backend.releases.clear();
    w.backend.failDevices = 404;
    expect(await w.run(['status']), 0, reason: w.output);
    expect(w.out.toString(), contains('The server does not know release $testReleaseId'));
    expect(w.out.toString(), contains('The device summary is not available'));
  });

  test('an unknown app is an error', () async {
    w = await OpsWorld.create();
    w.backend.apps.clear();
    expect(await w.run(['status']), 1);
    expect(w.err.toString(), contains('has no application with id $testAppId'));
  });

  test('the admin key is required', () async {
    w = await OpsWorld.create();
    expect(await w.run(['status'], drop: {'FLUTTER_OTA_ADMIN_KEY'}), 1);
    expect(w.err.toString(), contains('FLUTTER_OTA_ADMIN_KEY'));
    expect(w.backend.requests, isEmpty);
  });

  test('a wrong admin key is reported', () async {
    w = await OpsWorld.create();
    expect(await w.run(['status'], extraEnv: {'FLUTTER_OTA_ADMIN_KEY': 'wrong'}), 1);
    expect(w.err.toString(), contains('HTTP 401'));
  });
}
