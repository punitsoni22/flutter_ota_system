import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ota_client/ota_client.dart';
import 'package:ota_client/src/bsdiff.dart';

// Golden values produced by backend/app/signing.py with a fixed test key (see README).
const _point =
    'BEccPnWMSQQoW7p+UxGO0PUkresHV9Jb0vjnsNdt+nFM3VIPesqKi5F6zDf1HejwybvjrYWDgucC3CWhLQn3qFg=';
const _payload = '{"banner":"hello"}';
const _payloadSha = '649c1d28a8d77ddfc94878c3f9a50f679358f408707dd4ee2fa0442883536b91';
const _signature =
    'VarizXNE6N2+1GP9H1GUQhQJM9/PelKokIB+6Ti3w6w71c3tt1Az2yV+vXrXClafWPaDszdUkIAHqz7092/rYQ==';

SignedFields _fields({int number = 1}) => SignedFields(
      applicationId: 'app-0001',
      releaseId: 'rel-0001',
      patchNumber: number,
      platform: 'android',
      arch: 'arm64-v8a',
      runtimeAbi: 'ota-runtime-v1',
      artifactFormat: 'mock-v1',
      baseArtifactSha256: '0' * 64,
      payloadSha256: _payloadSha,
      resultSha256: _payloadSha,
      sizeBytes: _payload.length,
    );

/// A fake server. Tests change [patch], [payload] and the bad lists between calls.
class FakeServer {
  Map<String, dynamic>? patch = _patchJson();
  String payload = _payload;
  List<int> rolledBack = [];
  int? rollbackTo;
  final events = <Map<String, dynamic>>[];
  int checks = 0;
  String? lastFailedIds;
  String? lastChannel;

  static Map<String, dynamic> _patchJson() => {
        'id': '11111111-1111-1111-1111-111111111111',
        'number': 1,
        'artifact_format': 'mock-v1',
        'arch': 'arm64-v8a',
        'runtime_abi': 'ota-runtime-v1',
        'download_url': 'http://cdn.test/cdn/patches/$_payloadSha',
        'base_artifact_sha256': '0' * 64,
        'payload_sha256': _payloadSha,
        'result_sha256': _payloadSha,
        'size_bytes': _payload.length,
        'signature': _signature,
        'key_id': 'test-1',
      };

  http.Client get client => MockClient((req) async {
        final path = req.url.path;
        if (path == '/v1/devices/register') {
          return http.Response(jsonEncode({'device_id': 'd', 'access_token': 't', 'expires_in': 3600}), 200);
        }
        if (path == '/v1/updates/check') {
          checks++;
          lastFailedIds = req.url.queryParameters['failed_patch_ids'];
          lastChannel = req.url.queryParameters['channel'];
          final current = int.parse(req.url.queryParameters['current_patch_number']!);
          final p = patch;
          final available = p != null && (p['number'] as int) != current;
          return http.Response(
            jsonEncode({
              'update_available': available,
              'application_id': 'app-0001',
              'release_id': 'rel-0001',
              'patch': available ? p : null,
              'rollback_to_patch_number': rolledBack.contains(current) ? (rollbackTo ?? 0) : null,
              'rolled_back_patch_numbers': rolledBack,
              'revoked_patch_numbers': <int>[],
              'next_check_after_seconds': 1800,
            }),
            200,
          );
        }
        if (path == '/v1/events/batch') {
          events.addAll(((jsonDecode(req.body) as Map)['events'] as List).cast<Map<String, dynamic>>());
          return http.Response('{}', 202);
        }
        if (path.startsWith('/cdn/')) return http.Response(payload, 200);
        return http.Response('not found', 404);
      });
}

/// Plays the native side (OtaBoot.java): picks next/good at each start, catches unconfirmed starts.
class FakeNativeRuntime implements NativeBootRuntime {
  String? nextId, goodId, attempt, loaded;
  final failed = <String>{};
  List<String> newlyFailed = [];

  /// A process start, before Dart runs. [visible] = an activity opened (a real app start).
  void processStart({bool visible = true}) {
    newlyFailed = [];
    if (attempt != null && attempt != goodId) {
      failed.add(attempt!);
      newlyFailed.add(attempt!);
    }
    attempt = null;
    loaded = [nextId, goodId].firstWhere((id) => id != null && !failed.contains(id), orElse: () => null);
    if (visible && loaded != null && loaded != goodId) attempt = loaded;
  }

  @override
  Set<String> get supportedFormats => const {'mock-v1'};
  @override
  String get runtimeAbi => 'ota-runtime-v1';

  @override
  Future<NativeBootReport> readBootReport() async =>
      NativeBootReport(enabled: true, loadedPatchId: loaded, failedPatchIds: newlyFailed);

  @override
  Future<void> setNextBoot({PatchRecord? next, Directory? nextDir, PatchRecord? good, Directory? goodDir}) async {
    nextId = next?.id;
    goodId = good?.id;
  }

  @override
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir) async {
    await patchDir.create(recursive: true);
    await verifiedPayload.rename('${patchDir.path}/libapp.so');
  }

  @override
  Future<void> load(PatchRecord? patch, Directory? patchDir) async {}
}

void main() {
  group('OTADIF01 binary patch', () {
    test('rebuilds the file the Python CLI diffed', () {
      final old = File('test/fixtures/old.bin').readAsBytesSync();
      final expected = File('test/fixtures/new.bin').readAsBytesSync();
      final patch = File('test/fixtures/patch.otadiff').readAsBytesSync();
      expect(applyOtaDiff(old, patch), expected);
    });

    test('rejects garbage and truncation', () {
      final old = File('test/fixtures/old.bin').readAsBytesSync();
      final patch = File('test/fixtures/patch.otadiff').readAsBytesSync();
      expect(() => applyOtaDiff(old, patch.sublist(0, patch.length - 1)), throwsFormatException);
      expect(() => applyOtaDiff(old, Uint8List.fromList(utf8.encode('nope'))), throwsFormatException);
    });
  });

  group('canonical encoding', () {
    test('matches the ADR-0002 test vector', () {
      final message = const SignedFields(
        applicationId: '6f629161-5d63-4caa-9174-0ad1b225ad37',
        releaseId: '7b831760-d896-433e-a4d2-825234657044',
        patchNumber: 3,
        platform: 'android',
        arch: 'arm64-v8a',
        runtimeAbi: 'ota-runtime-v1',
        artifactFormat: 'mock-v1',
        baseArtifactSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        payloadSha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        resultSha256: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        sizeBytes: 1834241,
      ).message();
      expect(message.length, 371);
      expect(sha256.convert(message).toString(),
          '2c53f97238a44c3bc7262a54e8c7ecd8e9ea105aa0b3c4fdc105fe38e78a8a79');
    });
  });

  group('signature', () {
    final verifier = SignatureVerifier({'test-1': _point});

    test('verifies a signature made by the Python backend', () {
      expect(verifier.verify('test-1', _fields().message(), _signature), isTrue);
    });

    test('rejects a changed field, unknown key and garbage', () {
      expect(verifier.verify('test-1', _fields(number: 2).message(), _signature), isFalse);
      expect(verifier.verify('other', _fields().message(), _signature), isFalse);
      expect(verifier.verify('test-1', _fields().message(), 'not-base64!'), isFalse);
    });
  });

  group('client', () {
    late Directory dir;
    late FakeServer server;
    late MockPatchRuntime runtime;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ota-client-test');
      server = FakeServer();
    });
    tearDown(() => dir.delete(recursive: true));

    /// Simulates one app start: new client, boot, return it.
    Future<OtaClient> start({String version = '1.0.0+1'}) async {
      runtime = MockPatchRuntime();
      final client = OtaClient(OtaConfig(
        serverUrl: 'http://api.test',
        appSlug: 'demo',
        releaseVersion: version,
        publicKeys: const {'test-1': _point},
        runtime: runtime,
        storageDir: dir,
        platform: 'android',
        arch: 'arm64-v8a',
        httpClient: server.client,
      ));
      await client.boot();
      return client;
    }

    String? activeText() => runtime.activePayload == null ? null : utf8.decode(runtime.activePayload!);

    test('download → verify → stage → active after restart → confirmed', () async {
      var app = await start();
      expect(activeText(), isNull);
      final result = await app.checkForUpdate();
      expect(result.status, UpdateStatus.stagedRestartRequired);
      expect(activeText(), isNull, reason: 'code never changes while running');

      app = await start();
      expect(activeText(), _payload);
      expect(app.activePatchNumber, 1);
      await app.markBootSuccessful();
      expect(server.events.map((e) => e['type']), contains('patch_boot_succeeded'), reason: 'reported right away');

      app = await start();
      expect(app.activePatchNumber, 1);
      await app.checkForUpdate(force: true);
      expect(server.events.map((e) => e['type']), containsAll(['patch_staged', 'patch_boot_succeeded']));
    });

    test('a patch that crashes on start falls back on the next start', () async {
      var app = await start();
      await app.checkForUpdate();
      app = await start(); // boots patch 1, "crashes" before markBootSuccessful
      expect(app.activePatchNumber, 1);

      app = await start(); // next start notices
      expect(app.activePatchNumber, 0);
      expect(activeText(), isNull);

      // It is never offered again on this device, and the server is told so it can offer another.
      final result = await app.checkForUpdate(force: true);
      expect(result.status, UpdateStatus.rejected);
      expect(server.lastFailedIds, '11111111-1111-1111-1111-111111111111');
      expect(server.events.map((e) => e['type']), containsAll(['patch_boot_failed', 'patch_auto_rollback']));
    });

    test('tampered download is rejected', () async {
      server.payload = '{"banner":"evil"}'.padRight(_payload.length);
      final app = await start();
      final result = await app.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, 'hash mismatch');
    });

    test('forged signature is rejected before download', () async {
      server.patch!['number'] = 2; // signature covers number 1
      final app = await start();
      final result = await app.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, 'signature invalid');
    });

    test('server rollback moves the device back to the store build', () async {
      var app = await start();
      await app.checkForUpdate();
      app = await start();
      await app.markBootSuccessful();

      server
        ..patch = null
        ..rolledBack = [1]
        ..rollbackTo = 0;
      final result = await app.checkForUpdate(force: true);
      expect(result.status, UpdateStatus.rollbackRestartRequired);

      app = await start();
      expect(app.activePatchNumber, 0);
    });

    test('a new store version drops old patches', () async {
      var app = await start();
      await app.checkForUpdate();
      app = await start();
      await app.markBootSuccessful();
      expect(app.activePatchNumber, 1);

      server.patch = null;
      app = await start(version: '1.1.0+2');
      expect(app.activePatchNumber, 0);
      expect(activeText(), isNull);
    });

    test('corrupted patch on disk is not loaded', () async {
      var app = await start();
      await app.checkForUpdate();
      final payload = File('${dir.path}/patches/11111111-1111-1111-1111-111111111111/payload');
      await payload.writeAsString('corrupted');
      app = await start();
      expect(app.activePatchNumber, 0);
      expect(activeText(), isNull);
    });

    test('checking again before restart reports the staged patch, not a replay', () async {
      final app = await start();
      expect((await app.checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
      final again = await app.checkForUpdate(force: true);
      expect(again.status, UpdateStatus.stagedRestartRequired);
      expect(again.patchNumber, 1);
    });

    test('a tester can switch channel at runtime, and it is kept across restarts', () async {
      var app = await start();
      await app.checkForUpdate();
      expect(server.lastChannel, 'production');

      await app.setChannel('staging');
      expect(app.channel, 'staging');
      await app.checkForUpdate(); // not throttled: switching resets the check interval
      expect(server.lastChannel, 'staging');

      app = await start();
      expect(app.channel, 'staging');
      await app.setChannel(null);
      expect(app.channel, 'production');
    });

    test('check interval is respected unless forced', () async {
      server.patch = null;
      final app = await start();
      await app.checkForUpdate();
      await app.checkForUpdate();
      expect(server.checks, 1);
      await app.checkForUpdate(force: true);
      expect(server.checks, 2);
    });
  });

  group('code patches (native boot)', () {
    late Directory dir;
    late FakeServer server;
    final native = FakeNativeRuntime();
    const id = '11111111-1111-1111-1111-111111111111';

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ota-native-test');
      server = FakeServer();
      native
        ..nextId = null
        ..goodId = null
        ..attempt = null
        ..failed.clear();
    });
    tearDown(() => dir.delete(recursive: true));

    Future<OtaClient> start({bool visible = true}) async {
      native.processStart(visible: visible);
      final client = OtaClient(OtaConfig(
        serverUrl: 'http://api.test',
        appSlug: 'demo',
        releaseVersion: '1.0.0+1',
        publicKeys: const {'test-1': _point},
        runtime: native,
        storageDir: dir,
        platform: 'android',
        arch: 'arm64-v8a',
        httpClient: server.client,
      ));
      await client.boot();
      return client;
    }

    test('staged patch is handed to native code, loads, and is confirmed as good', () async {
      var app = await start();
      await app.checkForUpdate();
      expect(native.nextId, id);
      expect(native.goodId, isNull);

      app = await start();
      expect(app.activePatchNumber, 1);
      await app.markBootSuccessful();
      expect(native.goodId, id);

      app = await start();
      expect(native.newlyFailed, isEmpty);
      expect(app.activePatchNumber, 1);
    });

    test('a start that never confirms is caught by native code and reported', () async {
      var app = await start();
      await app.checkForUpdate();
      app = await start(); // runs patch 1, dies before markBootSuccessful
      expect(app.activePatchNumber, 1);

      app = await start();
      expect(app.activePatchNumber, 0, reason: 'store code runs');
      expect(native.nextId, isNull, reason: 'Dart stops asking for the failed patch');
      final result = await app.checkForUpdate(force: true);
      expect(result.status, UpdateStatus.rejected);
      expect(server.lastFailedIds, id);
      expect(server.events.map((e) => e['type']), containsAll(['patch_boot_failed', 'patch_auto_rollback']));
    });

    test('a background start (push, job) without UI is not counted as a failure', () async {
      var app = await start();
      await app.checkForUpdate();
      await start(visible: false); // e.g. a push woke the process; main() never confirmed
      app = await start();
      expect(native.newlyFailed, isEmpty);
      expect(app.activePatchNumber, 1);
    });

    test('server rollback points the next start back at the store code', () async {
      var app = await start();
      await app.checkForUpdate();
      app = await start();
      await app.markBootSuccessful();
      server
        ..patch = null
        ..rolledBack = [1]
        ..rollbackTo = 0;
      expect((await app.checkForUpdate(force: true)).status, UpdateStatus.rollbackRestartRequired);
      expect(native.nextId, isNull);
      expect(native.goodId, isNull, reason: 'a rolled-back patch is no fallback either');
      app = await start();
      expect(app.activePatchNumber, 0);
    });
  });
}
