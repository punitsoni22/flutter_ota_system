// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/user_config.dart';
import '../context.dart';
import '../errors.dart';
import '../toolchain/transport.dart';

/// Environment variable with the server's admin API key (sent as `X-API-Key`). The CLI never
/// writes this key to any file: not to the project, not to the user config.
const adminKeyEnv = 'FLUTTER_OTA_ADMIN_KEY';

/// Android ABI name the backend uses for arm64 release artifacts.
const arm64Arch = 'arm64-v8a';

/// An HTTP error from the backend, with its `detail` text.
class ServerException extends CliException {
  ServerException(this.statusCode, String message) : super(message);
  final int statusCode;
}

/// Resolves the server URL (flag > `FLUTTER_OTA_SERVER_URL` > user config). Null when unset.
String? resolveServerUrl(CliContext ctx, {String? flag}) {
  final v = UserConfig.load(ctx.environment).resolve('server-url', ctx.environment, flag: flag).value;
  if (v == null || v.isEmpty) return null;
  return validateSetting('server-url', v);
}

/// Message for a missing server URL.
const missingServerUrlMessage =
    'No server URL is configured. Set it once with:\n'
    '  flutter_ota config set server-url https://ota.example.com\n'
    '(or export FLUTTER_OTA_SERVER_URL for one shell).';

/// Message for a missing admin key.
const missingAdminKeyMessage =
    'The admin API key is missing. Export it for this shell only, for example:\n'
    '  read -rs FLUTTER_OTA_ADMIN_KEY && export FLUTTER_OTA_ADMIN_KEY\n'
    'In CI, store it as a secret environment variable. flutter_ota never saves it in a file.';

/// Small client for the backend admin API (`X-API-Key`) and the health endpoint.
class AdminClient {
  AdminClient(this.baseUrl, this.adminKey, this._client);

  /// Builds a client from the configuration; throws [CliException] with guidance when the server
  /// URL or the admin key is missing.
  factory AdminClient.fromContext(CliContext ctx, {String? serverUrlFlag}) {
    final url = resolveServerUrl(ctx, flag: serverUrlFlag);
    if (url == null) throw CliException(missingServerUrlMessage);
    final key = ctx.environment[adminKeyEnv];
    if (key == null || key.trim().isEmpty) throw CliException(missingAdminKeyMessage);
    return AdminClient(url, key.trim(), ctx.httpClientFactory());
  }

  final String baseUrl;
  final String adminKey;
  final http.Client _client;

  static const _timeout = Duration(seconds: 60);

  void close() => _client.close();

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> get _headers => {'X-API-Key': adminKey, 'Accept': 'application/json'};

  /// `GET /health/live`. Returns null when healthy, else a short reason.
  Future<String?> health() async {
    try {
      final r = await _client.get(_uri('/health/live')).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) return null;
      return 'HTTP ${r.statusCode}';
    } on Exception catch (e) {
      return '$e';
    }
  }

  Future<Object?> _send(String method, String path, {Object? json}) async {
    final req = http.Request(method, _uri(path))..headers.addAll(_headers);
    if (json != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(json);
    }
    return _decode(await _execute(req), method, path);
  }

  Future<http.Response> _execute(http.BaseRequest req) async {
    try {
      return await http.Response.fromStream(await _client.send(req).timeout(_timeout));
    } on Exception catch (e) {
      throw CliException('Cannot reach the server at $baseUrl: $e');
    }
  }

  Object? _decode(http.Response r, String method, String path) {
    if (r.statusCode == 401) {
      throw ServerException(401, 'The server refused the admin key (HTTP 401). Check $adminKeyEnv.');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      var detail = r.body;
      try {
        final j = jsonDecode(r.body);
        if (j is Map && j['detail'] != null) {
          detail = j['detail'] is String ? j['detail'] as String : jsonEncode(j['detail']);
        }
      } on FormatException {
        // keep the raw body
      }
      if (detail.length > 600) detail = '${detail.substring(0, 600)}...';
      throw ServerException(r.statusCode, '$method $path failed (HTTP ${r.statusCode}): $detail');
    }
    if (r.body.isEmpty) return null;
    try {
      return jsonDecode(r.body);
    } on FormatException {
      throw CliException('$method $path: the server sent a response that is not JSON.');
    }
  }

  /// All applications (`GET /v1/admin/apps`).
  Future<List<Map<String, Object?>>> listApps() async =>
      ((await _send('GET', '/v1/admin/apps')) as List).cast<Map<String, Object?>>();

  /// The application with UUID [appId], or null.
  Future<Map<String, Object?>?> findApp(String appId) async {
    for (final a in await listApps()) {
      if (a['id'] == appId) return a;
    }
    return null;
  }

  /// Trust state: roots, certificates, revocation lists (`GET /v1/admin/apps/{app}/trust`).
  Future<Map<String, Object?>> trust(String appId) async =>
      (await _send('GET', '/v1/admin/apps/$appId/trust')) as Map<String, Object?>;

  /// Registers a root public key (201 new, 200 same key again, 409 other key with that id).
  Future<void> registerRoot(String appId, String keyId, String publicKey) async {
    await _send('POST', '/v1/admin/apps/$appId/trust/roots', json: {'key_id': keyId, 'public_key': publicKey});
  }

  /// Uploads a root-signed key certificate (201 new, 200 same certificate again).
  Future<void> uploadCertificate(String appId, Map<String, Object?> certificate) async {
    await _send('POST', '/v1/admin/apps/$appId/trust/certificates', json: certificate);
  }

  /// Releases of the app. The release routes take the app slug.
  Future<List<Map<String, Object?>>> listReleases(String slug) async =>
      ((await _send('GET', '/v1/admin/apps/$slug/releases')) as List).cast<Map<String, Object?>>();

  /// `POST /v1/admin/apps/{slug}/releases`.
  Future<Map<String, Object?>> createRelease(String slug, Map<String, Object?> body) async =>
      (await _send('POST', '/v1/admin/apps/$slug/releases', json: body)) as Map<String, Object?>;

  /// Patches of a release, lowest number first (`GET /v1/admin/releases/{id}/patches`).
  Future<List<Map<String, Object?>>> listPatches(String releaseId) async =>
      ((await _send('GET', '/v1/admin/releases/$releaseId/patches')) as List).cast<Map<String, Object?>>();

  /// Rolls a published patch back (`POST /v1/admin/patches/{id}/rollback`, no request body).
  /// The server answers 409 when the patch is not published.
  Future<Map<String, Object?>> rollbackPatch(String patchId) async =>
      (await _send('POST', '/v1/admin/patches/$patchId/rollback')) as Map<String, Object?>;

  /// Device counts by platform, release version, channel and patch number, from each device's
  /// last check (`GET /v1/admin/apps/{slug}/devices/summary`).
  Future<List<Map<String, Object?>>> deviceSummary(String slug) async =>
      ((await _send('GET', '/v1/admin/apps/$slug/devices/summary')) as List).cast<Map<String, Object?>>();

  /// Uploads the release's base file for one ABI (multipart `arch` + `file`).
  Future<Map<String, Object?>> uploadReleaseArtifact(String releaseId, String arch, Uint8List bytes) async {
    final path = '/v1/admin/releases/$releaseId/artifacts';
    final req = http.MultipartRequest('POST', _uri(path))
      ..headers.addAll(_headers)
      ..fields['arch'] = arch
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'libapp.so'));
    return _decode(await _execute(req), 'POST', path) as Map<String, Object?>;
  }
}

/// True for `https://` URLs and `http://` to this machine.
bool isAllowedServerUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return false;
  return u.scheme == 'https' || (u.scheme == 'http' && isLoopbackHost(u.host));
}
