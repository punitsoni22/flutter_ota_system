// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/keys/key_store.dart';
import 'package:flutter_ota_cli/src/server/admin_client.dart';
import 'package:flutter_ota_cli/src/server/app_state.dart';
import 'package:flutter_ota_cli/src/toolchain/canonical_json.dart';
import 'package:flutter_ota_cli/src/toolchain/es256.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../release_android/release_support.dart';

void main() {
  late ReleaseWorld w;
  setUp(() async => w = await ReleaseWorld.create());
  tearDown(() => w.dispose());

  group('keys init', () {
    test('creates root + signer outside the project, registers only public data', () async {
      expect(await w.run(['keys', 'init']), 0, reason: w.output);
      final store = AppKeyStore.forApp(w.env(), appId);
      expect(store.dir, p.join(w.configDir, 'keys', appId));
      expect(p.isWithin(w.project, store.dir), isFalse);

      // Private key files: mode 0600, folders 0700.
      final keyFiles = Directory(
        store.dir,
      ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.key')).toList();
      expect(keyFiles, hasLength(2));
      for (final f in keyFiles) {
        expect(f.statSync().mode & 0x1ff, 0x180, reason: f.path); // 0600
      }
      expect(Directory(store.dir).statSync().mode & 0x1ff, 0x1c0); // 0700

      // Server got the public root and a certificate that verifies with it.
      final roots = store.rootPublicKeys();
      expect(w.backend.roots.single['public_key'], roots.values.single);
      final cert = w.backend.certificates.single['certificate'] as Map<String, Object?>;
      final body = cert['body'] as Map<String, Object?>;
      expect(body.keys.toSet(), {
        'type',
        'app_id',
        'environment',
        'key_id',
        'public_key',
        'roles',
        'serial',
        'not_before',
        'not_after',
      });
      expect(body['app_id'], appId);
      expect(body['roles'], ['signer']);
      expect(body['environment'], 'production');
      expect(body['not_after'] as String, matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')));
      final ok = es256Verify(
        parseEs256PublicKey(roots.values.single),
        domainMessage(keyCertificateDomain, canonicalJson(body)),
        cert['sig'] as String,
      );
      expect(ok, isTrue);

      // No private key went to the server.
      final sent = w.backend.requests.map((r) => latin1.decode(r.body)).join('\n');
      for (final f in keyFiles) {
        expect(sent, isNot(contains(f.readAsStringSync().trim())));
      }
      expect(Directory(w.project).listSync(recursive: true).where((e) => e.path.endsWith('.key')), isEmpty);
    });

    test('running it again reuses the keys', () async {
      expect(await w.run(['keys', 'init']), 0);
      final before = AppKeyStore.forApp(w.env(), appId).signers().single.keyId;
      expect(await w.run(['keys', 'init']), 0, reason: w.output);
      final store = AppKeyStore.forApp(w.env(), appId);
      expect(store.rootPublicKeys(), hasLength(1));
      expect(store.signers().single.keyId, before);
      expect(w.backend.roots, hasLength(1));
    });

    test('another environment gets its own signer certificate', () async {
      expect(await w.run(['keys', 'init']), 0);
      expect(await w.run(['keys', 'init', '--environment', 'staging']), 0, reason: w.output);
      final store = AppKeyStore.forApp(w.env(), appId);
      expect(store.signers().map((s) => s.environment).toSet(), {'production', 'staging'});
      expect(store.activeSigner('staging', DateTime.now()), isNotNull);
    });

    test('keys list works offline', () async {
      expect(await w.run(['keys', 'init']), 0);
      w.out.clear();
      expect(await w.run(['keys', 'list'], drop: {'FLUTTER_OTA_SERVER_URL', 'FLUTTER_OTA_ADMIN_KEY'}), 0);
      expect(w.out.toString(), contains('(private key on this machine)'));
      expect(w.out.toString(), contains('production'));
    });

    test('needs the admin key', () async {
      expect(await w.run(['keys', 'init'], drop: {'FLUTTER_OTA_ADMIN_KEY'}), 1);
      expect(w.err.toString(), contains('FLUTTER_OTA_ADMIN_KEY'));
      expect(Directory(p.join(w.configDir, 'keys')).existsSync(), isFalse);
    });
  });

  group('root key selection', () {
    ServerAppState state(Map<String, String> active, {Set<String> revoked = const {}}) =>
        ServerAppState(appId, appSlug, active, revoked, []);

    test('only keys that are local AND registered are embedded', () {
      final sel = selectRootKeys({'r1': 'A', 'r2': 'B'}, state({'r1': 'A', 'r3': 'C'}));
      expect(sel.embedded, {'r1': 'A'});
      expect(sel.warnings.join('\n'), contains('r2 is not registered'));
      expect(sel.warnings.join('\n'), contains('r3, which is not on this machine'));
    });

    test('revoked, missing and conflicting roots', () {
      expect(() => selectRootKeys({}, state({'r1': 'A'})), throwsA(isA<CliException>()));
      expect(() => selectRootKeys({'r1': 'A'}, state({}, revoked: {'r1'})), throwsA(isA<CliException>()));
      expect(
        () => selectRootKeys({'r1': 'A'}, state({'r1': 'X'})),
        throwsA(predicate((e) => e is CliException && e.message.contains('DIFFERENT'))),
      );
    });
  });

  group('admin client', () {
    test('sends X-API-Key and maps errors to clear messages', () async {
      final c = AdminClient(w.backend.url, adminKey, http.Client());
      try {
        expect(await c.health(), isNull);
        expect((await c.findApp(appId))!['slug'], appSlug);
        expect(await c.findApp('00000000-0000-4000-8000-000000000000'), isNull);
        await expectLater(
          c.createRelease('unknown-app', {}),
          throwsA(predicate((e) => e is ServerException && e.statusCode == 404 && e.message.contains('not found'))),
        );
      } finally {
        c.close();
      }
      final bad = AdminClient(w.backend.url, 'wrong', http.Client());
      try {
        await expectLater(bad.listApps(), throwsA(predicate((e) => e is ServerException && e.statusCode == 401)));
      } finally {
        bad.close();
      }
    });

    test('unreachable server', () async {
      final c = AdminClient('http://127.0.0.1:1', adminKey, http.Client());
      try {
        expect(await c.health(), isNotNull);
        await expectLater(
          c.listApps(),
          throwsA(predicate((e) => e is CliException && e.message.contains('Cannot reach'))),
        );
      } finally {
        c.close();
      }
    });

    test('server URL rules', () {
      expect(isAllowedServerUrl('https://ota.example.com'), isTrue);
      expect(isAllowedServerUrl('http://127.0.0.1:8000'), isTrue);
      expect(isAllowedServerUrl('http://ota.example.com'), isFalse);
    });
  });
}
