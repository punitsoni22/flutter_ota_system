// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Device API calls of the bytecode runtime (phase-4-backend-protocol.md, section 5):
//   POST /v1/devices/register   with application_id (UUID)
//   GET  /v1/updates/check      with supported_formats=dbc-v1
//   GET  <download_url>         the OTAPRT02 container
//   POST /v1/events/batch       device events
// Every URL passes the SDK's transport rules (release builds: https only, redirects checked).
// Never called on the start-up path.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../patch_id.dart';
import '../security/security.dart' show maxContainerBytes;
import '../transport.dart';
import 'patch_store.dart';

/// A `dbc-v1` patch offered by the server.
class DbcPatchOffer {
  const DbcPatchOffer({
    required this.serverId,
    required this.number,
    required this.arch,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.sha256,
    required this.patchId,
    required this.sequence,
  });

  /// Server patch id (UUID): used for events and `failed_patch_ids`.
  final String serverId;
  final int number;
  final String arch;
  final String downloadUrl;

  /// Size and SHA-256 of the whole container.
  final int sizeBytes;
  final String sha256;

  /// `patch_id` and `sequence` copied from the signed manifest (checked against it).
  final String patchId;
  final int sequence;

  ServerPatchRef get ref => ServerPatchRef(serverId, number);
}

/// The parts of the update-check response the bytecode runtime uses.
class DbcCheckResponse {
  const DbcCheckResponse({
    required this.applicationId,
    required this.releaseId,
    required this.patch,
    required this.otherFormat,
    required this.badPatchNumbers,
    required this.revocations,
    required this.revocationsReleaseId,
    required this.nextCheckAfterSeconds,
  });

  final String applicationId;
  final String? releaseId;

  /// The offered patch if it is `dbc-v1`.
  final DbcPatchOffer? patch;

  /// Format of an offered patch that is not `dbc-v1` (ignored by this runtime), if any.
  final String? otherFormat;

  /// Rolled-back and revoked patch numbers of the release (ADR-0005).
  final Set<int> badPatchNumbers;

  /// The newest root-signed revocation list, byte for byte, if the server has one.
  final Uint8List? revocations;
  final String? revocationsReleaseId;
  final int nextCheckAfterSeconds;

  /// Parses the JSON body. Throws [FormatException] for a malformed response.
  factory DbcCheckResponse.fromJson(Map<String, Object?> j) {
    T need<T>(Map<String, Object?> o, String k) {
      final v = o[k];
      if (v is! T) throw FormatException('update check: "$k" is missing or has the wrong type');
      return v;
    }

    DbcPatchOffer? offer;
    String? other;
    final p = j['patch'];
    if (j['update_available'] == true && p is Map<String, Object?>) {
      final format = need<String>(p, 'artifact_format');
      if (format == 'dbc-v1') {
        offer = DbcPatchOffer(
          serverId: need<String>(p, 'id'),
          number: need<int>(p, 'number'),
          arch: need<String>(p, 'arch'),
          downloadUrl: need<String>(p, 'download_url'),
          sizeBytes: need<int>(p, 'size_bytes'),
          sha256: need<String>(p, 'sha256'),
          patchId: need<String>(p, 'patch_id'),
          sequence: need<int>(p, 'sequence'),
        );
      } else {
        other = format;
      }
    }
    Uint8List? revocations;
    String? revocationsRelease;
    final r = j['revocations'];
    if (r is Map<String, Object?>) {
      revocations = base64.decode(need<String>(r, 'data_base64'));
      revocationsRelease = r['release_id'] as String?;
    }
    List<int> ints(String k) => ((j[k] as List?) ?? const []).whereType<int>().toList();
    return DbcCheckResponse(
      applicationId: need<String>(j, 'application_id'),
      releaseId: j['release_id'] as String?,
      patch: offer,
      otherFormat: other,
      badPatchNumbers: {...ints('rolled_back_patch_numbers'), ...ints('revoked_patch_numbers')},
      revocations: revocations,
      revocationsReleaseId: revocationsRelease,
      nextCheckAfterSeconds: j['next_check_after_seconds'] as int? ?? 1800,
    );
  }
}

/// Thrown when a download does not match the offered size.
class DownloadSizeError implements Exception {
  const DownloadSizeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Device registration (by application id), update check, download and events.
class UpdateApi {
  UpdateApi({
    required this.serverUrl,
    required this.applicationId,
    required this.deviceFile,
    required http.Client client,
  }) : _http = SecureRedirectClient(client, allowLoopbackHttp: true);

  final String serverUrl;
  final String applicationId;

  /// `<store>/device.json`: installation id and access token.
  final File deviceFile;
  final http.Client _http;

  Map<String, Object?>? _device;

  Map<String, Object?> get _dev {
    if (_device != null) return _device!;
    try {
      _device = (jsonDecode(deviceFile.readAsStringSync()) as Map).cast<String, Object?>();
    } catch (_) {
      _device = {};
    }
    if (_device!['installation_id'] is! String) {
      final rnd = Random.secure();
      _device!['installation_id'] = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _saveDevice();
    }
    return _device!;
  }

  void _saveDevice() => PatchStore.atomicWrite(deviceFile, utf8.encode(jsonEncode(_device)));

  /// Random id of this installation (not tied to the person or the hardware).
  String get installationId => _dev['installation_id']! as String;

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('${serverUrl.replaceAll(RegExp(r'/+$'), '')}$path').replace(queryParameters: query);
    final problem = insecureUrlProblem(uri, allowLoopbackHttp: true);
    if (problem != null) throw InsecureUrlException(problem);
    return uri;
  }

  Future<void> _register({
    required String platform,
    required String arch,
    required String releaseVersion,
    required String channel,
  }) async {
    final r = await _http
        .post(
          _uri('/v1/devices/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'application_id': applicationId,
            'installation_id': installationId,
            'platform': platform,
            'arch': arch,
            'release_version': releaseVersion,
            'channel': channel,
          }),
        )
        .timeout(otaTimeouts.request);
    if (r.statusCode != 200) throw HttpException('register failed: HTTP ${r.statusCode}');
    _dev['access_token'] = (jsonDecode(r.body) as Map<String, Object?>)['access_token']! as String;
    _saveDevice();
  }

  Future<http.Response> _authed(
    Future<http.Response> Function(Map<String, String> headers) send,
    Future<void> Function() register,
  ) async {
    if (_dev['access_token'] is! String) await register();
    var r = await send({'Authorization': 'Bearer ${_dev['access_token']}'});
    if (r.statusCode == 401) {
      await register();
      r = await send({'Authorization': 'Bearer ${_dev['access_token']}'});
    }
    return r;
  }

  late Future<void> Function() _lastRegister = () async => throw StateError('check() was not called');

  /// `GET /v1/updates/check` with `supported_formats=dbc-v1`.
  Future<DbcCheckResponse> check({
    required String platform,
    required String arch,
    required String releaseVersion,
    required String channel,
    required int currentPatchNumber,
    required List<String> failedPatchIds,
  }) async {
    _lastRegister = () =>
        _register(platform: platform, arch: arch, releaseVersion: releaseVersion, channel: channel);
    final uri = _uri('/v1/updates/check', {
      'platform': platform,
      'arch': arch,
      'release_version': releaseVersion,
      'channel': channel,
      'current_patch_number': '$currentPatchNumber',
      'supported_formats': 'dbc-v1',
      if (failedPatchIds.isNotEmpty) 'failed_patch_ids': failedPatchIds.where(isValidPatchId).join(','),
    });
    final r = await _authed((h) => _http.get(uri, headers: h).timeout(otaTimeouts.request), _lastRegister);
    if (r.statusCode != 200) throw HttpException('check failed: HTTP ${r.statusCode}');
    return DbcCheckResponse.fromJson((jsonDecode(r.body) as Map).cast<String, Object?>());
  }

  /// Streams the container into [target]; refuses more or fewer bytes than offered. Every stage
  /// has a time limit (SEC-15).
  Future<void> download(DbcPatchOffer p, File target) async {
    if (p.sizeBytes <= 0 || p.sizeBytes > maxContainerBytes) {
      throw DownloadSizeError('offered size ${p.sizeBytes} is out of range');
    }
    final uri = Uri.parse(p.downloadUrl);
    final problem = insecureUrlProblem(uri, allowLoopbackHttp: true);
    if (problem != null) throw InsecureUrlException(problem);
    final t = otaTimeouts;
    final total = Stopwatch()..start();
    final response = await _http
        .send(http.Request('GET', uri))
        .timeout(t.downloadResponse, onTimeout: () => throw TimeoutException('download: no response'));
    if (response.statusCode != 200) {
      unawaited(response.stream.listen(null).cancel());
      throw HttpException('download failed: HTTP ${response.statusCode}');
    }
    target.parent.createSync(recursive: true);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(
        t.downloadIdle,
        onTimeout: (s) {
          s.addError(TimeoutException('download stalled', t.downloadIdle));
          s.close();
        },
      )) {
        if (total.elapsed > t.downloadTotal) throw TimeoutException('download too slow', t.downloadTotal);
        received += chunk.length;
        if (received > p.sizeBytes) throw const DownloadSizeError('download is larger than offered');
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (received != p.sizeBytes) throw const DownloadSizeError('download is shorter than offered');
  }

  /// `POST /v1/events/batch`. Returns true if the server took the batch (or refused it as
  /// malformed, so it must not be retried).
  Future<bool> sendEvents(List<Map<String, String>> events) async {
    if (events.isEmpty) return true;
    final r = await _authed(
      (h) => _http
          .post(
            _uri('/v1/events/batch'),
            headers: {...h, 'Content-Type': 'application/json'},
            body: jsonEncode({'events': events}),
          )
          .timeout(otaTimeouts.request),
      _lastRegister,
    );
    return r.statusCode == 202 || r.statusCode == 422;
  }
}
