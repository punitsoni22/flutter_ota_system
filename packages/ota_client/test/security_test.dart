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
import 'package:flutter_ota_system/flutter_ota_system.dart';
import 'package:flutter_ota_system/src/native_boot.dart';
import 'package:flutter_ota_system/src/test_overrides.dart';
import 'package:flutter_ota_system/src/patch_id.dart';
import 'package:flutter_ota_system/src/transport.dart';

const _javaPaths = 'android/src/main/java/io/github/punitsoni22/flutter_ota_system/OtaPaths.java';

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
  String? lastFailedIds;

  /// Every URL requested (scheme://host:port/path), in order, with its Authorization header.
  final seen = <String>[];
  final authorization = <String, String?>{};

  /// Return a target to answer a request with a redirect to it.
  Uri? Function(Uri url)? redirectTo;
  int redirectStatus = 302;

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
        final key = '${req.url.scheme}://${req.url.authority}${req.url.path}';
        seen.add(key);
        authorization[key] = req.headers['authorization'];
        final target = redirectTo?.call(req.url);
        if (target != null) {
          return http.Response('', redirectStatus, headers: {'location': '$target'});
        }
        final path = req.url.path;
        if (path == '/v1/devices/register') {
          return http.Response(jsonEncode({'device_id': 'd', 'access_token': 't', 'expires_in': 3600}), 200);
        }
        if (path.startsWith('/v1/updates/check')) {
          lastFailedIds = req.url.queryParameters['failed_patch_ids'];
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

/// A native boot report naming path-like ids (tampered native.json / boot.json).
class _BadReportRuntime implements NativeBootRuntime {
  @override
  Set<String> get supportedFormats => const {'mock-v1'};
  @override
  String get runtimeAbi => 'ota-runtime-v1';
  @override
  Future<NativeBootReport> readBootReport() async =>
      const NativeBootReport(enabled: true, loadedPatchId: '../..', failedPatchIds: ['../..', '..', 'x/y']);
  @override
  Future<void> setNextBoot({PatchRecord? next, Directory? nextDir, PatchRecord? good, Directory? goodDir}) async {}
  @override
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir) async {
    await patchDir.create(recursive: true);
    await verifiedPayload.rename('${patchDir.path}/libapp.so');
  }
  @override
  Future<void> load(PatchRecord? patch, Directory? patchDir) async {}
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
    debugOtaTestOverrides = null;
    if (await parent.exists()) await parent.delete(recursive: true);
  });

  Future<OtaClient> start({
    String serverUrl = 'https://api.test',
    String applicationId = 'app-0001',
    http.Client? httpClient,
  }) async {
    runtime = MockPatchRuntime();
    debugOtaTestOverrides = OtaTestOverrides(storageDir: dir, platform: 'android', arch: 'arm64-v8a');
    final client = OtaClient(OtaConfig(
      serverUrl: serverUrl,
      appSlug: 'demo',
      releaseVersion: '1.0.0+1',
      publicKeys: const {'test-1': _point},
      runtime: runtime,
      applicationId: applicationId,
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
    test('applicationId is required and must not be empty', () {
      expect(
        () => OtaConfig(
          serverUrl: 'https://api.test',
          appSlug: 'demo',
          applicationId: '',
          releaseVersion: '1.0.0+1',
          publicKeys: const {},
          runtime: MockPatchRuntime(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('using the client before boot() fails clearly', () async {
      final client = OtaClient(OtaConfig(
        serverUrl: 'https://api.test',
        appSlug: 'demo',
        applicationId: 'app-0001',
        releaseVersion: '1.0.0+1',
        publicKeys: const {'test-1': _point},
        runtime: MockPatchRuntime(),
        httpClient: server.client,
      ));
      expect(() => client.installationId, throwsStateError);
      expect(() => client.channel, throwsStateError);
      expect(client.setChannel('staging'), throwsStateError);
      expect(client.activePatch, isNull);
      expect((await client.checkForUpdate()).status, UpdateStatus.failed);
      expect(server.requests, 0);
    });

    test('a pinned applicationId refuses another application\'s response', () async {
      server.applicationId = 'app-0002';
      final client = await start(applicationId: 'app-0001');
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, 'application id mismatch');
      expect(server.downloads, 0);
    });

    test('a patch signed for one application fails verification when offered as another', () async {
      // The app and the response agree on app-0002, but the patch was signed for app-0001.
      server.applicationId = 'app-0002';
      final client = await start(applicationId: 'app-0002');
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
      'http://localhost:8000': (true, false),
      'http://127.0.0.1:8000': (true, false),
      'http://127.1.2.3': (true, false),
      'http://[::1]:8000': (true, false),
      'http://LOCALHOST:8000': (true, false),
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
      expect(result.message, 'insecure URL http://ota.example.com: release builds require https://');
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

    for (final url in ['http://localhost:8000', 'http://127.0.0.1:8000', 'http://[::1]:8000']) {
      test('release: $url is refused (no localhost exception)', () async {
        debugReleaseModeOverride = true;
        final client = await start(serverUrl: url);
        final result = await client.checkForUpdate();
        expect(result.status, UpdateStatus.failed);
        expect(result.message, endsWith('release builds require https://'));
        expect(server.requests, 0);
      });

      test('debug: $url works', () async {
        debugReleaseModeOverride = false;
        final client = await start(serverUrl: url);
        expect((await client.checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
      });
    }

    test('release: an http://127.0.0.1 download URL is refused before downloading', () async {
      debugReleaseModeOverride = true;
      server.downloadUrl = 'http://127.0.0.1:8080/cdn/patches/$_payloadSha';
      final client = await start();
      final result = await client.checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, 'insecure URL http://127.0.0.1:8080: release builds require https://');
      expect(server.downloads, 0);
    });

    test('debug: an http://localhost download URL works', () async {
      server.downloadUrl = 'http://localhost:8080/cdn/patches/$_payloadSha';
      final client = await start();
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

  group('SEC-02 redirects', () {
    const cdn = 'https://cdn.test/cdn/patches/$_payloadSha';
    Uri? Function(Uri) redirect(String fromUrl, String to) =>
        (u) => '${u.scheme}://${u.authority}${u.path}' == fromUrl ? Uri.parse(to) : null;

    for (final release in [false, true]) {
      final mode = release ? 'release' : 'debug';

      test('$mode: an https download redirected to another https host is followed (CDN/bucket)', () async {
        debugReleaseModeOverride = release;
        server.redirectTo = redirect(cdn, 'https://bucket.test/cdn/patches/$_payloadSha');
        final result = await (await start()).checkForUpdate();
        expect(result.status, UpdateStatus.stagedRestartRequired, reason: '$result');
        expect(server.seen, contains('https://bucket.test/cdn/patches/$_payloadSha'));
      });

      test('$mode: a relative https redirect is resolved and followed', () async {
        debugReleaseModeOverride = release;
        server.redirectTo = redirect(cdn, '/cdn/patches/moved');
        server.redirectStatus = 308;
        final result = await (await start()).checkForUpdate();
        expect(result.status, UpdateStatus.stagedRestartRequired, reason: '$result');
        expect(server.seen, contains('https://cdn.test/cdn/patches/moved'));
      });

      for (final target in ['http://cdn.test/cdn/patches/x', 'http://localhost:8080/cdn/patches/x']) {
        test('$mode: an https download redirected to $target is refused (no downgrade)', () async {
          debugReleaseModeOverride = release;
          server.redirectTo = redirect(cdn, target);
          final result = await (await start()).checkForUpdate();
          expect(result.status, UpdateStatus.rejected, reason: '$result');
          expect(result.message, contains('downgrades are never followed'));
          expect(server.seen.where((u) => u.startsWith('http://')), isEmpty, reason: 'never requested');
          expect(server.downloads, 0);
        });
      }

      test('$mode: a redirect to a non-http scheme is refused', () async {
        debugReleaseModeOverride = release;
        server.redirectTo = redirect(cdn, 'ftp://cdn.test/x');
        final result = await (await start()).checkForUpdate();
        expect(result.status, UpdateStatus.rejected);
        expect(result.message, contains('unsupported URL scheme "ftp"'));
      });

      test('$mode: an API redirect from https to http is refused before the http request', () async {
        debugReleaseModeOverride = release;
        server.redirectTo = (u) => u.host == 'api.test' && u.path == '/v1/updates/check' ? u.replace(scheme: 'http') : null;
        final result = await (await start()).checkForUpdate();
        expect(result.status, UpdateStatus.failed);
        expect(result.message, contains('downgrades are never followed'));
        expect(server.seen.where((u) => u.startsWith('http://')), isEmpty);
      });
    }

    test('debug: an http://localhost redirect to a LAN address is refused (every hop is checked)', () async {
      server.downloadUrl = 'http://localhost:8080/cdn/patches/$_payloadSha';
      server.redirectTo = redirect('http://localhost:8080/cdn/patches/$_payloadSha', 'http://192.168.1.10/cdn/x');
      final result = await (await start()).checkForUpdate();
      expect(result.status, UpdateStatus.rejected);
      expect(result.message, contains('insecure URL http://192.168.1.10'));
      expect(server.seen, isNot(contains('http://192.168.1.10/cdn/x')));
    });

    test('debug: an http://localhost redirect to http://localhost is followed', () async {
      server.downloadUrl = 'http://localhost:8080/cdn/patches/$_payloadSha';
      server.redirectTo = redirect('http://localhost:8080/cdn/patches/$_payloadSha', '/cdn/patches/moved');
      expect((await (await start()).checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
    });

    test('a redirect loop stops after 5 hops', () async {
      server.redirectTo = (u) => u.host == 'cdn.test' ? u.replace(path: '${u.path}x') : null;
      final result = await (await start()).checkForUpdate();
      expect(result.status, UpdateStatus.failed);
      expect(result.message, contains('too many redirects'));
      expect(server.seen.where((u) => u.contains('cdn.test')).length, 6, reason: '1 request + 5 redirects');
    });

    test('a redirect without Location fails', () async {
      server.redirectTo = (u) => u.host == 'cdn.test' ? Uri() : null;
      final result = await (await start()).checkForUpdate();
      expect(result.status, UpdateStatus.failed);
      expect(result.message, contains('redirect without Location'));
    });

    test('the device token is not forwarded when a redirect changes the host', () async {
      server.redirectTo = (u) => u.host == 'api.test' && u.path == '/v1/updates/check' ? u.replace(host: 'other.test') : null;
      final result = await (await start()).checkForUpdate();
      expect(result.status, UpdateStatus.stagedRestartRequired);
      expect(server.authorization['https://api.test/v1/updates/check'], 'Bearer t');
      expect(server.authorization['https://other.test/v1/updates/check'], isNull);
    });

    test('the device token is kept on a same-origin redirect', () async {
      server.redirectTo = (u) => u.path == '/v1/updates/check' ? u.replace(path: '/v1/updates/check2') : null;
      expect((await (await start()).checkForUpdate()).status, UpdateStatus.stagedRestartRequired);
      expect(server.authorization['https://api.test/v1/updates/check2'], 'Bearer t');
    });

    test('POST requests do not follow redirects', () async {
      server.redirectTo = (u) => u.path == '/v1/devices/register' ? u.replace(host: 'other.test') : null;
      server.redirectStatus = 307;
      final result = await (await start()).checkForUpdate();
      expect(result.status, UpdateStatus.failed);
      expect(result.message, contains('register failed: HTTP 307'));
      expect(server.seen, isNot(contains('https://other.test/v1/devices/register')));
    });
  });

  group('SEC-01 patch ids: Dart and Android agree, native ids are filtered', () {
    test('OtaPaths.java uses exactly the Dart pattern', () {
      final java = File(_javaPaths).readAsStringSync();
      expect(java, contains('"$patchIdPatternSource"'));
    });

    test('invalid ids in the native boot report are ignored and never sent to the server', () async {
      runtime = MockPatchRuntime();
      debugOtaTestOverrides = OtaTestOverrides(storageDir: dir, platform: 'android', arch: 'arm64-v8a');
      final client = OtaClient(OtaConfig(
        serverUrl: 'https://api.test',
        appSlug: 'demo',
        releaseVersion: '1.0.0+1',
        publicKeys: const {'test-1': _point},
        applicationId: 'app-0001',
        runtime: _BadReportRuntime(),
        httpClient: server.client,
      ));
      await client.boot();
      expect(client.activePatch, isNull);
      await client.checkForUpdate();
      expect(server.lastFailedIds, isNull, reason: 'no invalid id is stored or reported');
      expectNothingOutsideStorage();
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
        if (req.uri.path == '/moved') mode = 'ok';
        switch (mode) {
          case 'redirectOk':
            await res.redirect(Uri.parse('/moved'));
          case 'redirectLan':
            await res.redirect(Uri.parse('http://10.0.2.3:1/x'));
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

    test('real sockets: a redirect is followed by our code, not by dart:io', () async {
      mode = 'redirectOk';
      final ota = await start(httpClient: client);
      expect((await checkTimed(ota)).status, UpdateStatus.stagedRestartRequired);
    });

    test('real sockets: dart:io does not follow a redirect to a refused host behind our back', () async {
      // If dart:io followed it, this would be a connection error to 10.0.2.3, not our refusal.
      mode = 'redirectLan';
      final ota = await start(httpClient: client);
      final result = await checkTimed(ota);
      expect(result.status, UpdateStatus.rejected, reason: '$result');
      expect(result.message, contains('insecure URL http://10.0.2.3:1'));
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
