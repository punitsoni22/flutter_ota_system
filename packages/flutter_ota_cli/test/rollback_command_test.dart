// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:test/test.dart';

import 'ops_support.dart';
import 'patch_support.dart';

void main() {
  late OpsWorld w;
  setUp(() async => w = await OpsWorld.create());
  tearDown(() => w.dispose());

  String idOf(int n) => serverPatch(n, 'published')['id'] as String;
  String? statusOf(int n) => w.backend.patches.firstWhere((x) => x['number'] == n)['status'] as String?;

  test('default target: the highest-numbered published patch', () async {
    w.backend.patches.addAll([
      serverPatch(1, 'published', channels: {'stable': 100}),
      serverPatch(2, 'published', channels: {'stable': 20}),
      serverPatch(3, 'draft'),
      serverPatch(4, 'rolled_back'),
    ]);
    expect(await w.run(['rollback', '--yes']), 0, reason: w.output);
    expect(w.backend.rollbacks.single.path, '/v1/admin/patches/${idOf(2)}/rollback');
    expect(w.backend.rollbacks.single.body, isEmpty);
    expect(statusOf(2), 'rolled_back');
    expect(statusOf(1), 'published');
    final out = w.out.toString();
    expect(out, contains('Patch:    2'));
    expect(out, contains('Channels: stable 20%'));
    expect(out, contains('the patch they ran before it, if they still have it (published now: 1)'));
    expect(out, contains('Patch 2 is now rolled_back.'));
    expect(w.prompts, isEmpty);
  });

  test('the only published patch: devices go back to the store code', () async {
    w.backend.patches.add(serverPatch(1, 'published', channels: {'stable': 100}));
    w.answers = ['y'];
    expect(await w.run(['rollback']), 0, reason: w.output);
    expect(w.prompts.single, contains('Roll back patch 1? [y/N]'));
    expect(w.out.toString(), contains('go back to the store code (no patch) at their next start'));
    expect(statusOf(1), 'rolled_back');
  });

  test('explicit --patch, --release and --reason', () async {
    w.backend.patches.addAll([serverPatch(1, 'published'), serverPatch(2, 'published')]);
    expect(
      await w.run(['rollback', '--release', testReleaseId, '--patch', '1', '--reason', 'crash on start', '--yes']),
      0,
      reason: w.output,
    );
    expect(w.backend.rollbacks.single.path, '/v1/admin/patches/${idOf(1)}/rollback');
    expect(statusOf(2), 'published');
    expect(w.out.toString(), contains('Reason:   crash on start'));
  });

  test('confirmation: "no" changes nothing', () async {
    w.backend.patches.add(serverPatch(1, 'published'));
    w.answers = ['n'];
    expect(await w.run(['rollback']), 1);
    expect(w.out.toString(), contains('Cancelled. Nothing was changed.'));
    expect(w.backend.rollbacks, isEmpty);
    expect(statusOf(1), 'published');
  });

  test('no terminal and no --yes: refuses and changes nothing', () async {
    w.backend.patches.add(serverPatch(1, 'published'));
    expect(await w.run(['rollback']), 1);
    expect(w.err.toString(), contains('no interactive terminal'));
    expect(w.err.toString(), contains('--yes'));
    expect(w.backend.rollbacks, isEmpty);
    expect(statusOf(1), 'published');
  });

  test('refuses a patch that is not published', () async {
    w.backend.patches.addAll([
      serverPatch(1, 'rolled_back'),
      serverPatch(2, 'draft'),
      serverPatch(3, 'revoked'),
      serverPatch(4, 'published'),
    ]);
    final expected = {1: 'it is already rolled back', 2: 'it is a draft that was never published', 3: 'it is revoked'};
    for (final e in expected.entries) {
      w.err.clear();
      expect(await w.run(['rollback', '--patch', '${e.key}', '--yes']), 1);
      expect(w.err.toString(), contains('Patch ${e.key} is not published: ${e.value}'));
    }
    expect(w.backend.rollbacks, isEmpty);
  });

  test('nothing published: nothing to roll back', () async {
    w.backend.patches.addAll([serverPatch(1, 'rolled_back'), serverPatch(2, 'draft')]);
    expect(await w.run(['rollback', '--yes']), 1);
    expect(w.err.toString(), contains('has no published patch'));
    expect(w.backend.rollbacks, isEmpty);
  });

  test('unknown patch number and bad --patch value', () async {
    w.backend.patches.add(serverPatch(1, 'published'));
    expect(await w.run(['rollback', '--patch', '7', '--yes']), 1);
    expect(w.err.toString(), contains('has no patch 7 on the server. Its patches are: 1.'));
    expect(await w.run(['rollback', '--patch', 'two', '--yes']), 64);
    expect(w.backend.rollbacks, isEmpty);
  });

  test('server errors are reported clearly', () async {
    w.backend.failPatchList = 500;
    expect(await w.run(['rollback', '--yes']), 1);
    expect(w.err.toString(), contains('HTTP 500'));
    expect(w.backend.rollbacks, isEmpty);
  });

  test('a 409 from the server (patch changed meanwhile) is explained', () async {
    w.backend.patches.add(serverPatch(1, 'published'));
    w.backend.rollbackConflict = 'Cannot roll back a revoked patch';
    expect(await w.run(['rollback', '--yes']), 1);
    expect(w.err.toString(), contains('The server refused the rollback'));
    expect(w.err.toString(), contains('Cannot roll back a revoked patch'));
    expect(w.err.toString(), contains('Nothing was changed.'));
  });

  test('an unregistered release or no local release is refused', () async {
    await w.dispose();
    w = await OpsWorld.create(registered: false);
    expect(await w.run(['rollback', '--yes']), 1);
    expect(w.err.toString(), contains('never registered on a server'));
    await w.dispose();
    w = await OpsWorld.create(withRelease: false);
    expect(await w.run(['rollback', '--yes']), 1);
    expect(w.err.toString(), contains('No store release found'));
    expect(w.backend.requests, isEmpty);
  });

  test('the admin key is required', () async {
    w.backend.patches.add(serverPatch(1, 'published'));
    expect(await w.run(['rollback', '--yes'], drop: {'FLUTTER_OTA_ADMIN_KEY'}), 1);
    expect(w.err.toString(), contains('FLUTTER_OTA_ADMIN_KEY'));
    expect(w.backend.requests, isEmpty);
  });
}
