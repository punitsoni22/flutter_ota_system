// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Shared setup of the status and rollback tests: a temporary project with a local release
// record, and a small fake of the backend admin routes these commands use.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:path/path.dart' as p;

import 'patch_support.dart';

const opsAdminKey = 'ops-test-admin-key';
const opsSlug = 'shop';

/// A server patch as `PatchOut` returns it.
Map<String, Object?> serverPatch(
  int number,
  String status, {
  Map<String, num> channels = const {},
  String format = 'dbc-v1',
}) => {
  'id': '00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}',
  'release_id': testReleaseId,
  'release_version': '1.0.0',
  'platform': 'android',
  'number': number,
  'artifact_format': format,
  'status': status,
  'note': '',
  'created_at': '2026-11-12T10:00:00Z',
  'artifacts': <Object?>[],
  'deployments': [
    for (final e in channels.entries) {'channel': e.key, 'rollout_percent': e.value.toDouble()},
  ],
  'event_counts': <String, int>{},
};

class OpsRequest {
  OpsRequest(this.method, this.path, this.body);
  final String method;
  final String path;
  final String body;
}

/// Fake backend: apps, the patches of [testReleaseId], the device summary and rollback.
class FakeOpsBackend {
  FakeOpsBackend._(this._server);

  static Future<FakeOpsBackend> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final b = FakeOpsBackend._(s);
    s.listen(b._handle);
    return b;
  }

  final HttpServer _server;
  final requests = <OpsRequest>[];
  final apps = <Map<String, Object?>>[
    {'id': testAppId, 'slug': opsSlug, 'name': 'Shop'},
  ];
  final releases = <String>{testReleaseId};
  final patches = <Map<String, Object?>>[];
  final devices = <Map<String, Object?>>[];

  /// When set, every patch-list request fails with this HTTP status.
  int? failPatchList;

  /// When set, the device summary fails with this HTTP status.
  int? failDevices;

  /// When set, the rollback route answers 409 as if the patch changed meanwhile.
  String? rollbackConflict;

  String get url => 'http://127.0.0.1:${_server.port}';

  Iterable<OpsRequest> get rollbacks => requests.where((r) => r.path.endsWith('/rollback'));

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final body = utf8.decode(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
    final path = req.uri.path;
    requests.add(OpsRequest(req.method, path, body));
    void send(int code, Object? json) {
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(json));
      req.response.close();
    }

    if (req.headers.value('x-api-key') != opsAdminKey) return send(401, {'detail': 'Invalid or missing X-API-Key'});
    final seg = path.split('/').where((s) => s.isNotEmpty).toList();
    if (req.method == 'GET' && path == '/v1/admin/apps') return send(200, apps);
    if (req.method == 'GET' && seg.length == 6 && seg[2] == 'apps' && seg[4] == 'devices' && seg[5] == 'summary') {
      if (!apps.any((a) => a['slug'] == seg[3])) return send(404, {'detail': 'Application not found'});
      if (failDevices != null) return send(failDevices!, {'detail': 'devices broken'});
      return send(200, devices);
    }
    if (req.method == 'GET' && seg.length == 5 && seg[2] == 'releases' && seg[4] == 'patches') {
      if (failPatchList != null) return send(failPatchList!, {'detail': 'database is down'});
      if (!releases.contains(seg[3])) return send(404, {'detail': 'Release not found'});
      return send(200, patches);
    }
    if (req.method == 'POST' && seg.length == 5 && seg[2] == 'patches' && seg[4] == 'rollback') {
      final pt = patches.where((x) => x['id'] == seg[3]).firstOrNull;
      if (pt == null) return send(404, {'detail': 'Patch not found'});
      if (rollbackConflict != null) return send(409, {'detail': rollbackConflict});
      if (pt['status'] != 'published') return send(409, {'detail': 'Cannot roll back a ${pt['status']} patch'});
      pt['status'] = 'rolled_back';
      return send(200, pt);
    }
    send(404, {'detail': 'not found: ${req.method} $path'});
  }
}

/// A temporary Flutter project with flutter_ota.yaml, a local release and a fake backend.
class OpsWorld {
  OpsWorld._(this.dir, this.backend);

  static Future<OpsWorld> create({bool withRelease = true, bool registered = true}) async {
    final dir = Directory.systemTemp.createTempSync('flutter_ota_ops_test').path;
    final w = OpsWorld._(dir, await FakeOpsBackend.start());
    Directory(w.project).createSync(recursive: true);
    File(p.join(w.project, 'pubspec.yaml')).writeAsStringSync('name: shop\n');
    File(p.join(w.project, projectFileName)).writeAsStringSync(projectFileContent(testAppId));
    if (withRelease) {
      writeTestRelease(w.project, rootKeys: const {}, hostPackages: const {'shop'}, registered: registered);
    }
    return w;
  }

  final String dir;
  final FakeOpsBackend backend;
  final out = StringBuffer();
  final err = StringBuffer();
  final prompts = <String>[];

  /// Answers for the prompts; null means "no terminal".
  List<String?> answers = [];

  String get project => p.join(dir, 'app');
  String get output => '$out\n$err';

  Future<void> dispose() async {
    await backend.close();
    Directory(dir).deleteSync(recursive: true);
  }

  Map<String, String> env() => {
    'HOME': p.join(dir, 'home'),
    'FLUTTER_OTA_CONFIG_DIR': p.join(dir, 'config'),
    'FLUTTER_OTA_SERVER_URL': backend.url,
    'FLUTTER_OTA_ADMIN_KEY': opsAdminKey,
  };

  Future<int> run(List<String> args, {Set<String> drop = const {}, Map<String, String> extraEnv = const {}}) => runCli(
    args,
    context: CliContext(
      environment: {...env(), ...extraEnv}..removeWhere((k, _) => drop.contains(k)),
      workingDirectory: project,
      out: out,
      err: err,
      prompt: (q) {
        prompts.add(q);
        return answers.isEmpty ? null : answers.removeAt(0);
      },
    ),
  );
}
