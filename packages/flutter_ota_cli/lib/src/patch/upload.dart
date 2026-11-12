// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Patch routes of the backend admin API (docs/architecture/phase-4-backend-protocol.md).
// Kept separate from lib/src/server/admin_client.dart (release pipeline) so the two milestones
// could be built in parallel; it uses the same server URL and admin key settings. Merge
// candidate: move these methods into AdminClient.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../errors.dart';
import '../server/admin_client.dart';

/// Artifact format of developer-signed bytecode patches.
const dbcFormat = 'dbc-v1';

class PatchServer {
  PatchServer(this.baseUrl, this.adminKey, this._client);

  final String baseUrl;
  final String adminKey;
  final http.Client _client;
  static const _timeout = Duration(seconds: 120);

  void close() => _client.close();

  Map<String, String> get _headers => {'X-API-Key': adminKey, 'Accept': 'application/json'};

  Future<Object?> _decode(http.BaseRequest req) async {
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(_timeout));
    } on Exception catch (e) {
      throw CliException('Cannot reach the server at $baseUrl: $e');
    }
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
      throw ServerException(r.statusCode, '${req.method} ${req.url.path} failed (HTTP ${r.statusCode}): $detail');
    }
    if (r.body.isEmpty) return null;
    try {
      return jsonDecode(r.body);
    } on FormatException {
      throw CliException('${req.method} ${req.url.path}: the server sent a response that is not JSON.');
    }
  }

  Future<Object?> _json(String method, String path, [Object? body]) {
    final req = http.Request(method, Uri.parse('$baseUrl$path'))..headers.addAll(_headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    return _decode(req);
  }

  /// Patches of a release (`GET /v1/admin/releases/{id}/patches`).
  Future<List<Map<String, Object?>>> listPatches(String releaseId) async =>
      ((await _json('GET', '/v1/admin/releases/$releaseId/patches')) as List).cast<Map<String, Object?>>();

  /// Highest manifest sequence of any dbc-v1 artifact of the release (0 when none).
  Future<int> highestSequence(String releaseId) async {
    var max = 0;
    for (final pt in await listPatches(releaseId)) {
      for (final a in (pt['artifacts'] as List? ?? const []).whereType<Map>()) {
        final s = a['sequence'];
        if (s is int && s > max) max = s;
      }
    }
    return max;
  }

  /// Creates a draft dbc-v1 patch.
  Future<Map<String, Object?>> createPatch(String releaseId, {String note = ''}) async =>
      (await _json('POST', '/v1/admin/releases/$releaseId/patches', {'artifact_format': dbcFormat, 'note': note}))
          as Map<String, Object?>;

  /// Uploads the signed container for one ABI. The server verifies it and stores it unchanged.
  Future<Map<String, Object?>> uploadArtifact(String patchId, String arch, Uint8List container) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/v1/admin/patches/$patchId/artifacts'))
      ..headers.addAll(_headers)
      ..fields['arch'] = arch
      ..files.add(http.MultipartFile.fromBytes('file', container, filename: 'patch.otp'));
    return (await _decode(req)) as Map<String, Object?>;
  }

  /// Publishes the patch to [channel] for [percent] % of devices.
  Future<Map<String, Object?>> publish(String patchId, String channel, int percent) async =>
      (await _json('POST', '/v1/admin/patches/$patchId/publish', {'channel': channel, 'rollout_percent': percent}))
          as Map<String, Object?>;
}
