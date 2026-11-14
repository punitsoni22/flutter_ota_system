// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:args/command_runner.dart';

import '../context.dart';
import '../errors.dart';
import '../server/admin_client.dart';
import 'project_server.dart';

/// `flutter_ota status`: the app, its newest (or chosen) store release, the release's patches on
/// the server and how many devices run what. Read-only.
class StatusCommand extends Command<int> {
  StatusCommand(this.ctx) {
    argParser
      ..addOption('release', help: 'Release id (UUID). Default: the newest local release.')
      ..addFlag('json', negatable: false, help: 'Print machine-readable JSON instead of text.');
  }

  final CliContext ctx;

  @override
  String get name => 'status';
  @override
  String get description =>
      'Show the app, the store release, its patches on the server (status, channels, rollout) and '
      'the device summary. Changes nothing.';

  @override
  Future<int> run() async {
    final a = argResults!;
    final project = OpsProject.load(ctx, releaseId: a['release'] as String?);
    final release = project.release;
    final url = resolveOpsServerUrl(ctx, release);
    final client = opsClient(ctx, url);
    try {
      final app = await client.findApp(project.appId);
      if (app == null) {
        throw CliException(
          'The server $url has no application with id ${project.appId} (the app_id in flutter_ota.yaml).\n'
          'List the apps with `ota app list` and copy the "id" of yours.',
        );
      }
      final slug = app['slug'] as String;

      List<Map<String, Object?>>? patches;
      String? patchesProblem;
      if (release == null) {
        patchesProblem = 'There is no local store release yet. Build one with:  flutter_ota release android';
      } else if (release.registered == null) {
        patchesProblem = 'Release ${release.releaseId} was never registered on a server, so it has no patches there.';
      } else {
        try {
          patches = await client.listPatches(release.releaseId);
        } on ServerException catch (e) {
          if (e.statusCode != 404) rethrow;
          patchesProblem = 'The server does not know release ${release.releaseId} (HTTP 404). Was it deleted there?';
        }
      }

      List<Map<String, Object?>>? devices;
      String? devicesProblem;
      try {
        devices = await client.deviceSummary(slug);
      } on ServerException catch (e) {
        if (e.statusCode == 401) rethrow;
        devicesProblem = 'The device summary is not available: ${e.message}';
      }

      final version = release?.version;
      final releaseDevices = devices == null
          ? null
          : (version == null ? devices : devices.where((d) => d['release_version'] == version).toList());

      if (a['json'] == true) {
        ctx.out.writeln(
          const JsonEncoder.withIndent('  ').convert({
            'server_url': url,
            'app': {'id': app['id'], 'slug': slug, 'name': app['name']},
            'release': release == null
                ? null
                : {
                    'id': release.releaseId,
                    'version': version,
                    'environment': release.environment,
                    'registered': release.registered != null,
                    'created_at': release.createdAt,
                  },
            'patches': patches
                ?.map(
                  (pt) => {
                    'number': patchNumber(pt),
                    'id': pt['id'],
                    'format': pt['artifact_format'],
                    'status': pt['status'],
                    'channels': [
                      for (final d in (pt['deployments'] as List? ?? const []).whereType<Map>())
                        {'channel': d['channel'], 'rollout_percent': d['rollout_percent']},
                    ],
                    'note': pt['note'],
                    'created_at': pt['created_at'],
                  },
                )
                .toList(),
            'patches_problem': patchesProblem,
            'devices': devices,
            'devices_problem': devicesProblem,
          }),
        );
        return 0;
      }

      final o = ctx.out;
      o.writeln('Server:   $url');
      o.writeln('App:      $slug  (id ${project.appId})');
      if (release == null) {
        o.writeln('Release:  (none on this machine)');
      } else {
        final reg = release.registered != null ? 'registered on the server' : 'NOT registered on a server';
        o.writeln('Release:  ${release.releaseId}');
        o.writeln('          version ${version ?? '?'}, environment ${release.environment}, $reg');
      }
      o.writeln('');
      if (patches == null) {
        o.writeln('Patches:  $patchesProblem');
      } else if (patches.isEmpty) {
        o.writeln('Patches:  none on the server for this release yet.');
        o.writeln('          Make one with:  flutter_ota patch android --channel <channel>');
      } else {
        o.writeln('Patches (${patches.length}):');
        // A rolled-back or revoked patch is no longer delivered: its channels are marked "(was)".
        // The column is as wide as its longest entry.
        String channels(Map<String, Object?> pt) =>
            pt['status'] == 'published' || pt['status'] == 'draft' ? channelsText(pt) : '(was) ${channelsText(pt)}';
        var w = 'CHANNELS (ROLLOUT)'.length;
        for (final pt in patches) {
          if (channels(pt).length > w) w = channels(pt).length;
        }
        o.writeln('  NO  STATUS       FORMAT   ${'CHANNELS (ROLLOUT)'.padRight(w)} PATCH ID');
        for (final pt in patches) {
          o.writeln(
            '  ${'${patchNumber(pt)}'.padRight(3)} ${'${pt['status']}'.padRight(12)} '
            '${'${pt['artifact_format']}'.padRight(8)} ${channels(pt).padRight(w)} ${pt['id']}',
          );
        }
        o.writeln('  published = devices can download it; draft = uploaded, not published yet;');
        o.writeln('  rolled_back = devices stopped using it; revoked = it must never run again.');
      }
      o.writeln('');
      if (releaseDevices == null) {
        o.writeln('Devices:  $devicesProblem');
      } else if (releaseDevices.isEmpty) {
        o.writeln('Devices:  no device has checked for updates yet${version == null ? '' : ' (version $version)'}.');
      } else {
        o.writeln('Devices (from their last update check${version == null ? '' : ', version $version'}):');
        for (final d in releaseDevices) {
          final n = d['patch_number'];
          final what = n == null ? 'store code (no patch)' : 'patch $n';
          final count = d['devices'];
          o.writeln('  ${d['platform']}, channel ${d['channel']}: $what - $count device${count == 1 ? '' : 's'}');
        }
      }
      return 0;
    } finally {
      client.close();
    }
  }
}
