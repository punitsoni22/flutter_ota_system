// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Security regression tests from the Step 3 audit:
//   SEC-01 patch ids that name paths, SEC-02 insecure URLs, SEC-15 timeouts,
//   plus cross-application rejection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ota_client/ota_client.dart';
import 'package:ota_client/src/patch_id.dart';
import 'package:ota_client/src/transport.dart';

// Golden values produced by backend/app/signing.py with a fixed test key (same as ota_client_test.dart).
const _point =
    'BEccPnWMSQQoW7p+UxGO0PUkresHV9Jb0vjnsNdt+nFM3VIPesqKi5F6zDf1HejwybvjrYWDgucC3CWhLQn3qFg=';
const _payload = '{"banner":"hello"}';
const _payloadSha = '649c1d28a8d77ddfc94878c3f9a50f679358f408707dd4ee2fa0442883536b91';
const _signature =
    'VarizXNE6N2+1GP9H1GUQhQJM9/PelKokIB+6Ti3w6w71c3tt1Az2yV+vXrXClafWPaDszdUkIAHqz7092/rYQ==';
const _goodId = '11111111-1111-1111-1111-111111111111';

/// A minimal update server. The patch is genuinely signed; tests change only unsigned fields.
class _Server {
  String id = _goodId;
  String downloadUrl = 'https://cdn.test/cdn/patches/$_payloadSha';
  String applicationId = 'app-0001';
  bool hangOnCheck = false;
  int requests = 0;
  int downloads = 0;

  Map<String, dynamic> get patch => {
        'id': id,
        'number': 1,
        'artifact_format': 'mock-v1',
        'arch': 'arm64-v8a',
        'runtime_abi': 'ota-runtime-v1',
        'download_url': downloadUrl,
        'base_artifact_sha256': '0' * 64,
        'payload_sha256': _payloadSha,
        'result_sha256': _payloadSha,
        'size_bytes': _payload.length,
        'signature': _signature,
        'key_id': 'test-1',
      };

  http.Client get client => MockClient((req) async {
        requests++;
        final path = req.url.path;
        if (path == '/v1/devices/register') {
          return http.Response(jsonEncode({'device_id': 'd', 'access_token': 't', 'expires_in': 3600}), 200);
        }
        if (path == '/v1/updates/check') {
          if (hangOnCheck) await Completer<void>().future; // never answers
          final current = int.parse(req.url.queryParameters['current_patch_number']!);
          return http.Response(
            jsonEncode({
              'update_available': current != 1,
              'application_id': applicationId,
              'release_id': 'rel-0001',
              'patch': current != 1 ? patch : null,
              'rollback_to_patch_number': null,
              'rolled_back_patch_numbers': <int>[],
              'revoked_patch_numbers': <int>[],
              'next_check_after_seconds': 1800,
            }),
            200,
          );
        }
        if (path == '/v1/events/batch') return http.Response('{}', 202);
        if (path.startsWith('/cdn/')) {
          downloads++;
          return http.Response(_payload, 200);
        }
        return http.Response('not found', 404);
      });
}

/// API calls go to the fake server; downloads from 127.0.0.1 go over real sockets.
class _RoutingClient extends http.BaseClient {
  _RoutingClient(this.api);
  final http.Client api;
  final http.Client real = createDefaultHttpClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      request.url.host == '127.0.0.1' ? real.send(request) : api.send(request);
}

void main() {
  late Directory parent;
  late Directory dir;
  late File sentinel;
  late _Server server;
  late MockPatchRuntime runtime;

  setUp(() async {
    // The client's storage is <parent>/ota. A file next to it must survive every attack.
    parent = await Directory.systemTemp.createTemp('ota-security-test');
    dir = Directory('${parent.path}/ota');
    sentinel = File('${parent.path}/keep.txt')..writeAsStringSync('user data');
    server = _Server();
  });
  tearDown(() async {
    debugReleaseModeOverride = null;
    debugOtaTimeouts = null;
    if (await parent.exists()) await parent.delete(recursive: true);
  });

  Future<OtaClient> start({
    String serverUrl = 'https://api.test',
    String? applicationId,
    http.Client? httpClient,
  }) async {
    runtime = MockPatchRuntime();
    final client = OtaClient(OtaConfig(
      serverUrl: serverUrl,
      appSlug: 'demo',
      releaseVersion: '1.0.0+1',
      publicKeys: const {'test-1': _point},
      runtime: runtime,
      applicationId: applicationId,
      storageDir: dir,
      platform: 'android',
      arch: 'arm64-v8a',
      httpClient: httpClient ?? server.client,
    ));
    await client.boot();
    return client;
  }

  void expectNothingOutsideStorage() {
    expect(sentinel.existsSync(), isTrue, reason: 'a file outside the OTA storage was deleted');
    final names = parent.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toSet();
    expect(names.difference({'ota', 'keep.txt'}), isEmpty, reason: 'something was written next to the OTA storage');
  }

  void expectNoLeftoverDownload() {
    final tmp = Directory('${dir.path}/tmp');
    expect(tmp.existsSync() ? tmp.listSync() : const [], isEmpty, reason: 'partial download left on disk');
  }

  group('SEC-01 patch ids', () {
    test('only canonical lowercase UUIDs are valid', () {
      expect(isValidPatchId(_goodId), isTrue);
      expect(isValidPatchId('0f8fad5b-d9cb-469f-a165-70867728950e'), isTrue);
      for (final bad in [
        '', '.', '..', '../..', 'a/b', '/etc', '0F8FAD5B-D9CB-469F-A165-70867728950E', '$_goodId\n', '$_goodId/..',
        '11111111-1111-1111-1111-11111111111', '11111111111111111111111111111111', 'x\u0000y',
      ]) {
        expect(isValidPatchId(bad), isFalse, reason: jsonEncode(bad));
      }
    });

    test('control: a signed patch with a valid id is staged', () async {
      final client = await start();
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.stagedRestartRequired, reason: '$result');
      expectNothingOutsideStorage();
    });

    for (final bad in ['../..', '../../keep.txt', '..', '.', '', 'a/b', '/tmp/x', 'x\u0000y', '0F8FAD5B-D9CB-469F-A165-70867728950E']) {
      test('a signed patch with id ${jsonEncode(bad)} is refused before any file operation', () async {
        server.id = bad;
        final client = await start();
        final result = await client.checkForUpdate();
        expect(result.status, UpdateStatus.rejected, reason: '$result');
        expect(result.message, 'invalid patch id');
        expect(server.downloads, 0, reason: 'refused before downloading');
        expectNothingOutsideStorage();
      });
    }

    test('a tampered state file naming a path is discarded: store build, nothing deleted', () async {
      await dir.create(recursive: true);
      final evil = {
        'id': '../..', 'number': 1, 'artifact_format': 'mock-v1', 'arch': 'arm64-v8a',
        'runtime_abi': 'ota-runtime-v1', 'download_url': 'https://cdn.test/x',
        'base_artifact_sha256': '0' * 64, 'payload_sha256': _payloadSha, 'result_sha256': _payloadSha,
        'size_bytes': 1, 'signature': _signature, 'key_id': 'test-1',
      };
      File('${dir.path}/state.json').writeAsStringSync(jsonEncode({
        'installation_id': 'abc', 'release_version': '1.0.0+1', 'active': evil, 'last_good': evil,
      }));
      final client = await start();
      expect(client.activePatch, isNull);
      expect(runtime.activePayload, isNull);
      expectNothingOutsideStorage();
    });
  });

  group('cross-application patches', () {
    test('a pinned applicationId refuses another application\'s response', () async {
      server.applicationId = 'app-0002';
      final client = await start(applicationId: 'app-0001');
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, 'application id mismatch');
      expect(server.downloads, 0);
    });

    test('a patch signed for one application fails verification when offered as another', () async {
      server.applicationId = 'app-0002'; // the signature covers app-0001
      final client = await start();
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, 'signature invalid');
      expect(server.downloads, 0);
    });
  });

  group('SEC-02 transport security', () {
    final cases = <String, (bool, bool)>{
      // url: (allowed in debug, allowed in release)
      'https://ota.example.com': (true, true),
      'https://10.0.2.2:8443': (true, true),
      'http://localhost:8000': (true, true),
      'http://127.0.0.1:8000': (true, true),
      'http://127.1.2.3': (true, true),
      'http://[::1]:8000': (true, true),
      'http://10.0.2.2:8000': (true, false),
      'http://ota.example.com': (false, false),
      'http://192.168.1.10:8000': (false, false),
      'http://localhost.evil.com': (false, false),
      'ftp://ota.example.com': (false, false),
      'file:///etc/passwd': (false, false),
      'https://': (false, false),
    };
    for (final release in [false, true]) {
      test('URL rules in ${release ? 'release' : 'debug'} builds', () {
        debugReleaseModeOverride = release;
        cases.forEach((url, allowed) {
          final ok = release ? allowed.$2 : allowed.$1;
          expect(insecureUrlProblem(Uri.parse(url)) == null, ok, reason: url);
        });
      });
    }

    test('release: an http:// server is refused before any request is sent', () async {
      debugReleaseModeOverride = true;
      final client = await start(serverUrl: 'http://ota.example.com');
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.failed);
      expect(result.message, 'insecure URL http://ota.example.com: release builds require https:// (http:// only for localhost)');
      expect(server.requests, 0);
    });

    test('release: the emulator address over http is refused', () async {
      debugReleaseModeOverride = true;
      final client = await start(serverUrl: 'http://10.0.2.2:8000');
      expect((await client.checkForUpdate()).status, UpdateStatus.failed);
      expect(server.requests, 0);
    });

    test('debug: the emulator address over http works', () async {
      debugReleaseModeOverride = false;
      final client = await start(serverUrl: 'http://10.0.2.2:8000');
      expect((await client.checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
    });

    test('debug: a LAN address over http is refused', () async {
      final client = await start(serverUrl: 'http://192.168.1.10:8000');
      expect((await client.checkForUpdate()).status, UpdateStatus.failed);
      expect(server.requests, 0);
    });

    test('release: http://localhost (adb reverse) works', () async {
      debugReleaseModeOverride = true;
      final client = await start(serverUrl: 'http://localhost:8000');
      expect((await client.checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
    });

    test('release: https works end to end', () async {
      debugReleaseModeOverride = true;
      final client = await start();
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.stagedRestartRequired);
      expect(server.downloads, 1);
    });

    test('release: an http:// download URL is refused before downloading', () async {
      debugReleaseModeOverride = true;
      server.downloadUrl = 'http://cdn.test/cdn/patches/$_payloadSha';
      final client = await start();
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, contains('release builds require https://'));
      expect(server.downloads, 0);
    });

    test('a non-http download URL is refused', () async {
      server.downloadUrl = 'file:///etc/passwd';
      final client = await start();
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, contains('unsupported URL scheme'));
    });
  });

  group('SEC-15 timeouts and broken downloads (real sockets on 127.0.0.1)', () {
    late HttpServer cdn;
    late String mode;
    late http.Client client;

    setUp(() async {
      mode = 'ok';
      cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      cdn.listen((req) async {
        final res = req.response;
        final body = utf8.encode(_payload);
        switch (mode) {
          case 'ok':
            res.contentLength = body.length;
            res.add(body);
            await res.close();
          case 'noHeaders':
            break; // never answers
          case 'stall':
            res.contentLength = body.length;
            res.add(body.sublist(0, 5));
            await res.flush(); // then nothing more
          case 'slow':
            // One byte every 100 ms, written straight to the socket (no HttpResponse buffering).
            res.contentLength = body.length;
            final socket = await res.detachSocket();
            socket.setOption(SocketOption.tcpNoDelay, true);
            for (final b in body) {
              socket.add([b]);
              await socket.flush();
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            await socket.close();
          case 'cut':
            // Headers promise the full size; the connection then dies after 5 bytes.
            res.contentLength = body.length;
            final socket = await res.detachSocket();
            socket.add(body.sublist(0, 5));
            await socket.flush();
            socket.destroy();
          case 'error':
            res.statusCode = 500;
            await res.close();
        }
      });
      server.downloadUrl = 'http://127.0.0.1:${cdn.port}/cdn/patches/$_payloadSha';
      client = _RoutingClient(server.client);
      debugOtaTimeouts = const OtaTimeouts(
        request: Duration(milliseconds: 300),
        downloadResponse: Duration(milliseconds: 300),
        downloadIdle: Duration(seconds: 1), // longer than the total, so "slow" hits the total limit
        downloadTotal: Duration(milliseconds: 400),
      );
    });
    tearDown(() => cdn.close(force: true));

    Future<UpdateResult> checkTimed(OtaClient ota, {Duration within = const Duration(seconds: 5)}) async {
      final watch = Stopwatch()..start();
      final result = await ota.checkForUpdate(force: true);
      expect(watch.elapsed, lessThan(within), reason: 'check must not hang');
      return result;
    }

    test('control: a real loopback http download works in debug builds', () async {
      final ota = await start(httpClient: client);
      expect((await checkTimed(ota)).status, UpdateStatus.stagedRestartRequired);
    });

    final failures = {
      'noHeaders': 'no response',
      'stall': 'stalled',
      'slow': 'too slow',
      'cut': '',
      'error': 'HTTP 500',
    };
    failures.forEach((m, message) {
      test('download "$m" fails cleanly, leaves no file, and the next check succeeds', () async {
        mode = m;
        final ota = await start(httpClient: client);
        final result = await checkTimed(ota);
        expect(result.status, UpdateStatus.failed, reason: '$result');
        expect(result.message, contains(message));
        expectNoLeftoverDownload();

        mode = 'ok';
        expect((await checkTimed(ota)).status, UpdateStatus.stagedRestartRequired,
            reason: 'a failed download must not block later checks');
      });
    });

    test('an update check that never answers fails after the request timeout', () async {
      server.hangOnCheck = true;
      final ota = await start(httpClient: client);
      final result = await checkTimed(ota);
      expect(result.status, UpdateStatus.failed);
      expect(result.message, contains('TimeoutException'));
    });

    test('the default HTTP client has a connect timeout', () {
      expect(createIoHttpClient().connectionTimeout, const Duration(seconds: 15));
      debugOtaTimeouts = const OtaTimeouts(connect: Duration(seconds: 3));
      expect(createIoHttpClient().connectionTimeout, const Duration(seconds: 3));
    });
  });
}
