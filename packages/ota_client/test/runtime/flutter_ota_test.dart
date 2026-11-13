// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// FlutterOta facade end to end on Linux: config, start-up, feature<T>, update check against a fake
// server (dbc-v1 response shape of phase-4-backend-protocol.md), separate-process verification
// (faked), activation at the next start, confirmation, events, revocations and rollbacks.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';
import 'package:flutter_ota_system/src/bytecode/runtime_platform.dart';
import 'package:flutter_ota_system/src/flutter_ota.dart' show FlutterOtaTestOverrides;
import 'package:flutter_ota_system/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/products_patch.dart' as patched;
import 'fixtures/products_store.dart' as store;
import 'support.dart';

/// Fake Flutter OTA System server (device endpoints only).
class FakeServer {
  final requests = <http.Request>[];
  final events = <Map<String, Object?>>[];
  Uint8List? container;
  int number = 1;
  String serverPatchId = '90000001-1111-4111-8111-111111111111';
  String? offeredPatchId;
  int? offeredSequence;
  String applicationId = appId;
  Uint8List? revocations;
  List<int> rolledBack = [];
  bool corruptDownload = false;

  late final client = MockClient((r) async {
    requests.add(r);
    switch (r.url.path) {
      case '/v1/devices/register':
        final b = jsonDecode(r.body) as Map;
        expect(b['application_id'], appId);
        expect(b.containsKey('app'), isFalse);
        return http.Response(jsonEncode({'device_id': 'd', 'access_token': 'tok', 'expires_in': 3600}), 200);
      case '/v1/updates/check':
        expect(r.headers['authorization'], 'Bearer tok');
        expect(r.url.queryParameters['supported_formats'], 'dbc-v1');
        return http.Response(jsonEncode(_check()), 200);
      case '/v1/events/batch':
        events.addAll(((jsonDecode(r.body) as Map)['events'] as List).cast<Map<String, Object?>>());
        return http.Response('{"accepted": 1}', 202);
      case '/files/patch.otp':
        final c = Uint8List.fromList(container!);
        if (corruptDownload) c[c.length - 1] ^= 1;
        return http.Response.bytes(c, 200);
    }
    return http.Response('not found', 404);
  });

  Map<String, Object?> _check() {
    final c = container;
    return {
      'update_available': c != null,
      'application_id': applicationId,
      'release_id': releaseId,
      if (c != null)
        'patch': {
          'id': serverPatchId,
          'number': number,
          'artifact_format': 'dbc-v1',
          'arch': 'arm64-v8a',
          'runtime_abi': 'dbc-v1',
          'download_url': 'https://ota.example.invalid/files/patch.otp',
          'base_artifact_sha256': libappSha,
          'payload_sha256': sha256.convert(c).toString(),
          'result_sha256': 'c' * 64,
          'size_bytes': c.length,
          'signature': null,
          'key_id': null,
          'sha256': sha256.convert(c).toString(),
          'patch_id': offeredPatchId ?? patchUuid(number),
          'sequence': offeredSequence ?? number,
        },
      'rolled_back_patch_numbers': rolledBack,
      'revoked_patch_numbers': <int>[],
      'next_check_after_seconds': 1800,
      if (revocations != null)
        'revocations': {'sequence': 1, 'release_id': releaseId, 'data_base64': base64.encode(revocations!)},
    };
  }

  Map<String, String> get lastCheckQuery =>
      requests.lastWhere((r) => r.url.path == '/v1/updates/check').url.queryParameters;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FakePlatform platform;
  late FakeServer server;
  late FakeModules modules;
  late List<String> logs;

  void useOverrides({String? define, bool android = true, http.Client? client}) {
    FlutterOta.debugOverrides = FlutterOtaTestOverrides(
      configDefine: define ?? configDefine(),
      platform: platform,
      httpClient: client ?? server.client,
      isAndroid: android,
      arch: 'arm64-v8a',
      log: logs.add,
      now: () => DateTime.utc(2026, 11, 12, 12),
    );
  }

  /// One app start.
  Future<void> start({bool withLoader = true}) async {
    FlutterOta.debugReset();
    await FlutterOta.initialize(moduleLoader: withLoader ? modules.load : null, checkForUpdates: false);
  }

  /// Patch [n] whose 'products' feature returns [feature].
  void offer(int n, {Object? Function()? feature}) {
    server.container = dbcContainer(n);
    server.number = n;
    server.serverPatchId = '9000000$n-1111-4111-8111-111111111111';
    modules.add(moduleBytes(n), () => <String, Object?>{
      'contract': 3,
      'features': <String, Object? Function()>{'products': feature ?? () => patched.ProductsFeature()},
    });
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flutter_ota_facade_');
    platform = FakePlatform(tmp);
    server = FakeServer();
    modules = FakeModules();
    logs = [];
    useOverrides();
  });

  tearDown(() {
    FlutterOta.debugReset();
    FlutterOta.debugOverrides = null;
    debugReleaseModeOverride = null;
    tmp.deleteSync(recursive: true);
  });

  group('disabled, never throws', () {
    test('no FLUTTER_OTA_CONFIG (plain flutter run): store code, a log line says why', () async {
      useOverrides(define: '');
      await start();
      expect(FlutterOta.status, FlutterOtaStatus.disabled);
      expect(FlutterOta.isEnabled, isFalse);
      expect(FlutterOta.disabledReason, contains('FLUTTER_OTA_CONFIG is not set'));
      expect(logs.single, startsWith('DISABLED'));
      expect(FlutterOta.feature<OtaFeature>('products', () => store.ProductsFeature()), isA<store.ProductsFeature>());
      expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.failed);
      expect(server.requests, isEmpty);
    });

    test('invalid config', () async {
      useOverrides(define: 'e30');
      await start();
      expect(FlutterOta.status, FlutterOtaStatus.disabled);
    });

    test('not Android', () async {
      useOverrides(android: false);
      await start();
      expect(FlutterOta.disabledReason, contains('Android only'));
    });

    test('no module loader registered', () async {
      await start(withLoader: false);
      expect(FlutterOta.disabledReason, contains('no module loader'));
    });

    test('a native failure during start-up disables OTA instead of throwing', () async {
      useOverrides();
      FlutterOta.debugOverrides = FlutterOtaTestOverrides(
        configDefine: configDefine(),
        platform: _ThrowingPlatform(),
        isAndroid: true,
        log: logs.add,
      );
      await start();
      expect(FlutterOta.status, FlutterOtaStatus.disabled);
      expect(FlutterOta.disabledReason, contains('start-up error'));
    });
  });

  test('no network on the start-up path; no libapp.so hashing without a patch', () async {
    await start();
    expect(FlutterOta.status, FlutterOtaStatus.storeCode);
    expect(server.requests, isEmpty);
    expect(platform.libappCalls, 0);
    expect(FlutterOta.lastStartupTimings, isNotNull);
  });

  test('update -> verify in separate process -> next start loads it -> confirmed -> events', () async {
    await start();
    offer(1);
    final r = await FlutterOta.checkForUpdate();
    expect(r.status, UpdateStatus.stagedRestartRequired, reason: '$r ${logs.join('\n')}');
    expect(platform.verifyCalls, 1);
    expect(FlutterOta.pendingPatchId, patchUuid(1));
    expect(FlutterOta.status, FlutterOtaStatus.storeCode, reason: 'never swapped live');
    expect(server.lastCheckQuery['current_patch_number'], '0');
    expect(server.lastCheckQuery['release_version'], '1.0.0+1');
    expect(server.events.map((e) => e['type']), ['patch_downloaded', 'patch_staged']);
    expect(server.events.first['patch_id'], server.serverPatchId);

    await start(); // app restart
    expect(FlutterOta.status, FlutterOtaStatus.patched, reason: logs.join('\n'));
    expect(FlutterOta.activePatch!.patchId, patchUuid(1));
    expect(FlutterOta.activePatch!.state, 'PROBATIONARY');
    expect(FlutterOta.activePatch!.serverNumber, 1);
    final f = FlutterOta.feature<OtaFeature>('products', () => store.ProductsFeature());
    expect(f, isA<patched.ProductsFeature>());
    final t = FlutterOta.lastStartupTimings!;
    expect(t.total, greaterThanOrEqualTo(t.verification));
    expect(logs.any((l) => l.startsWith('STARTUP total_ms=')), isTrue);

    FlutterOta.debugConfirmStart();
    expect(FlutterOta.activePatch!.state, 'ACTIVE');
    server.container = null;
    expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.upToDate);
    expect(server.lastCheckQuery['current_patch_number'], '1');
    expect(server.events.map((e) => e['type']), contains('patch_boot_succeeded'));
  });

  group('feature<T> uses only host-owned contract types (contract section 3)', () {
    setUp(() async {
      await start();
      offer(1);
      await FlutterOta.checkForUpdate();
      await start();
    });

    test('host-owned OtaFeature: the patch implementation is used', () {
      final f = FlutterOta.feature<OtaFeature>('products', () => store.ProductsFeature());
      expect((f as dynamic).version, 'patch');
    });

    test('same-named but different class (renamed copy) is not the store type: falls back, logs once', () {
      final f1 = FlutterOta.feature<store.ProductsFeature>('products', () => store.ProductsFeature());
      final f2 = FlutterOta.feature<store.ProductsFeature>('products', () => store.ProductsFeature());
      expect(f1.version, 'store');
      expect(f2.version, 'store');
      expect(logs.where((l) => l.startsWith('FEATURE_WRONG_TYPE products')), hasLength(1));
    });

    test('a feature the patch does not provide uses the store code', () {
      expect(FlutterOta.feature<OtaFeature>('cart', () => store.ProductsFeature()), isA<store.ProductsFeature>());
    });
  });

  test('a patch factory that returns a wrong type never crashes', () async {
    await start();
    offer(1, feature: () => 42);
    // The (fake) verifier process calls the factory too; it accepts any non-null value.
    expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
    await start();
    expect(FlutterOta.feature<OtaFeature>('products', () => store.ProductsFeature()), isA<store.ProductsFeature>());
  });

  test('error before confirmation after a patched feature was used: live fallback + failure counted', () async {
    await start();
    offer(1);
    await FlutterOta.checkForUpdate();
    await start();
    FlutterOta.feature<OtaFeature>('products', () => store.ProductsFeature());
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom in build')));
    expect(logs, contains(predicate<String>((l) => l.startsWith('LIVE_FALLBACK'))));
    expect(FlutterOta.feature<OtaFeature>('products', () => store.ProductsFeature()), isA<store.ProductsFeature>());
    expect(FlutterOta.debugPatchState(patchUuid(1)), 'SUSPECTED_FAILURE');
    expect(FlutterOta.status, FlutterOtaStatus.storeCode);
  });

  test('a module that fails to load at start counts as a failure; store code runs', () async {
    await start();
    offer(1);
    await FlutterOta.checkForUpdate();
    modules.add(moduleBytes(1), () => throw StateError('entry threw'));
    await start();
    expect(FlutterOta.status, FlutterOtaStatus.storeCode);
    expect(logs, contains(predicate<String>((l) => l.startsWith('MODULE_LOAD_FAILED'))));
    expect(FlutterOta.debugPatchState(patchUuid(1)), 'SUSPECTED_FAILURE');
  });

  group('refused offers', () {
    setUp(() async => start());

    test('separate-process verification REJECTED/CRASHED -> blacklisted, never activated', () async {
      offer(1);
      platform.forcedOutcome = const VerifyOutcome('CRASHED', 'verifier process died');
      final r = await FlutterOta.checkForUpdate();
      expect(r.status, UpdateStatus.rejected);
      expect(FlutterOta.pendingPatchId, isNull);
      expect(FlutterOta.debugPatchState(patchUuid(1)), 'BLACKLISTED');
      platform.forcedOutcome = null;
      expect((await FlutterOta.checkForUpdate()).message, contains('previously failed'));
      expect(server.lastCheckQuery['failed_patch_ids'], server.serverPatchId);
    });

    test('verifier UNAVAILABLE -> not activated, not blacklisted', () async {
      offer(1);
      platform.forcedOutcome = const VerifyOutcome('UNAVAILABLE', 'engine did not start');
      expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.failed);
      expect(FlutterOta.pendingPatchId, isNull);
      expect(FlutterOta.debugPatchState(patchUuid(1)), 'DOWNLOADED');
    });

    test('verifier EVICTED (low-memory kill) -> not blacklisted; a later check stages it', () async {
      offer(1);
      platform.forcedOutcome = const VerifyOutcome('EVICTED', 'verifier killed by the system for low memory');
      final r = await FlutterOta.checkForUpdate();
      expect(r.status, UpdateStatus.failed);
      expect(r.message, contains('low memory (1/$maxVerifierEvictions)'));
      expect(FlutterOta.pendingPatchId, isNull);
      expect(FlutterOta.debugPatchState(patchUuid(1)), 'DOWNLOADED');
      platform.forcedOutcome = null;
      expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
      expect(FlutterOta.pendingPatchId, patchUuid(1));
    });

    test('verifier EVICTED $maxVerifierEvictions times -> blacklisted (bounded retries)', () async {
      offer(1);
      platform.forcedOutcome = const VerifyOutcome('EVICTED', 'verifier killed by the system for low memory');
      for (var i = 1; i < maxVerifierEvictions; i++) {
        expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.failed);
      }
      final last = await FlutterOta.checkForUpdate();
      expect(last.status, UpdateStatus.rejected);
      expect(last.message, contains('EVICTED'));
      expect(FlutterOta.debugPatchState(patchUuid(1)), 'BLACKLISTED');
    });

    test('the in-VM verifier refusing the module (clean error) -> REJECTED', () async {
      server.container = dbcContainer(1);
      server.number = 1; // no module registered: the fake loader fails like a verification error
      final r = await FlutterOta.checkForUpdate();
      expect(r.status, UpdateStatus.rejected);
      expect(r.message, contains('REJECTED'));
    });

    test('container changed in transit (SHA-256 mismatch)', () async {
      offer(1);
      server.corruptDownload = true;
      expect((await FlutterOta.checkForUpdate()).message, contains('SHA-256'));
      expect(platform.verifyCalls, 0);
    });

    test('server metadata differs from the signed manifest', () async {
      offer(1);
      server.offeredPatchId = patchUuid(7);
      expect((await FlutterOta.checkForUpdate()).message, contains('differs from the signed manifest'));
    });

    test('patch signed by a key certified by another root', () async {
      offer(1);
      server.container = dbcContainer(1, certOverride: cert(signer, by: otherRoot));
      expect((await FlutterOta.checkForUpdate()).message, contains('[untrusted_root]'));
    });

    test('response for another application', () async {
      server.applicationId = '7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e6';
      expect((await FlutterOta.checkForUpdate()).message, 'application id mismatch');
    });
  });

  group('revocations and rollbacks from the update response', () {
    setUp(() async {
      await start();
      offer(1);
      await FlutterOta.checkForUpdate();
      await start();
      FlutterOta.debugConfirmStart();
      server.container = null;
    });

    test('a root-signed list revoking the active patch: restart required, store code next start', () async {
      server.revocations = revocationList(1, patchIds: [patchUuid(1)]);
      expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.rollbackRestartRequired);
      expect(logs, contains(predicate<String>((l) => l.startsWith('REVOCATIONS applied sequence=1'))));
      await start();
      expect(FlutterOta.status, FlutterOtaStatus.storeCode);
      expect(logs, contains(predicate<String>((l) => l.startsWith('STORED_PATCH_INVALID [revoked]'))));
    });

    test('a list not signed by a root of this app is ignored', () async {
      server.revocations = revocationList(1, patchIds: [patchUuid(1)], by: otherRoot);
      expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.upToDate);
      expect(logs, contains(predicate<String>((l) => l.startsWith('REJECTED revocation list [bad_signature]'))));
      await start();
      expect(FlutterOta.status, FlutterOtaStatus.patched);
    });

    test('the same list again is not applied twice (monotonic sequence)', () async {
      server.revocations = revocationList(1, keyIds: ['old-key']);
      await FlutterOta.checkForUpdate();
      await FlutterOta.checkForUpdate();
      expect(logs.where((l) => l.startsWith('REVOCATIONS applied')), hasLength(1));
    });

    test('server rollback of the active patch number', () async {
      server.rolledBack = [1];
      expect((await FlutterOta.checkForUpdate()).status, UpdateStatus.rollbackRestartRequired);
      await start();
      expect(FlutterOta.status, FlutterOtaStatus.storeCode);
    });
  });

  group('transport: release builds use https, plain http only to loopback', () {
    test('insecureUrlProblem: loopback allowed only when opted in (bytecode runtime)', () {
      debugReleaseModeOverride = true;
      for (final ok in ['http://127.0.0.1:8000/x', 'http://localhost:8000/', 'http://[::1]:8000/', 'https://ota.example.com']) {
        expect(insecureUrlProblem(Uri.parse(ok), allowLoopbackHttp: true), isNull, reason: ok);
      }
      for (final bad in ['http://10.0.2.2:8000/', 'http://192.168.1.5:8000/', 'http://ota.example.com/', 'ftp://127.0.0.1/']) {
        expect(insecureUrlProblem(Uri.parse(bad), allowLoopbackHttp: true), isNotNull, reason: bad);
      }
      // The classic OtaClient keeps https-only in release builds.
      expect(insecureUrlProblem(Uri.parse('http://127.0.0.1:8000/')), isNotNull);
    });

    test('release build: update check over http://127.0.0.1 works (real sockets, adb reverse setup)', () async {
      debugReleaseModeOverride = true;
      // The test binding answers every dart:io request with 400; use real sockets here.
      final savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = savedOverrides);
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      http.listen((req) async {
        seen.add(req.uri.path);
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path == '/v1/devices/register') {
          req.response.write(jsonEncode({'device_id': 'd', 'access_token': 'tok', 'expires_in': 60}));
        } else if (req.uri.path == '/v1/updates/check') {
          req.response.write(jsonEncode({
            'update_available': false,
            'application_id': appId,
            'release_id': releaseId,
            'rolled_back_patch_numbers': <int>[],
            'revoked_patch_numbers': <int>[],
            'next_check_after_seconds': 60,
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      try {
        useOverrides(define: configDefine(serverUrl: 'http://127.0.0.1:${http.port}'), client: createDefaultHttpClient());
        await start();
        final r = await FlutterOta.checkForUpdate();
        expect(r.status, UpdateStatus.upToDate, reason: '$r');
        expect(seen, ['/v1/devices/register', '/v1/updates/check']);
      } finally {
        await http.close(force: true);
      }
    });

    test('release build: http to a LAN host is refused before any request', () async {
      debugReleaseModeOverride = true;
      useOverrides(define: configDefine(serverUrl: 'http://192.168.1.5:8000'));
      await start();
      final r = await FlutterOta.checkForUpdate();
      expect(r.status, UpdateStatus.failed);
      expect(r.message, contains('release builds require https'));
      expect(server.requests, isEmpty);
    });
  });
}

class _ThrowingPlatform implements FlutterOtaPlatform {
  @override
  Future<NativeStartupInfo> startupInfo() async => throw const SocketException('channel broken');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
