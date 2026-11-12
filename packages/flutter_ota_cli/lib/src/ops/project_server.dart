// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Shared helpers of `flutter_ota status` and `flutter_ota rollback`: the project, its local
// release record and a connection to the server's admin API.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../context.dart';
import '../errors.dart';
import '../patch/release_record.dart';
import '../project/project.dart';
import '../server/admin_client.dart';

/// The Flutter project in (or above) the working directory, and its local store release.
class OpsProject {
  OpsProject(this.dir, this.appId, this.release);

  final String dir;

  /// `app_id` from flutter_ota.yaml.
  final String appId;

  /// The chosen local release; null when there is none and none was asked for.
  final ReleaseRecord? release;

  /// Loads the project. With [releaseId], that local release must exist. Without it, the newest
  /// local release is used; when there is none, [release] is null unless [requireRelease].
  static OpsProject load(CliContext ctx, {String? releaseId, bool requireRelease = false}) {
    final dir = findProjectDir(ctx.workingDirectory);
    if (dir == null) throw CliException('No $projectFileName found. Run `flutter_ota init` first.');
    final appId = readAppId(dir);
    ReleaseRecord? release;
    if (releaseId != null || requireRelease || _hasLocalRelease(dir)) {
      release = ReleaseRecord.find(dir, releaseId: releaseId?.trim().toLowerCase());
      if (release.appId != appId) {
        throw CliException(
          'The local release ${release.releaseId} belongs to app ${release.appId}, but '
          '$projectFileName has app_id $appId.',
        );
      }
    }
    return OpsProject(dir, appId, release);
  }

  static bool _hasLocalRelease(String dir) {
    final root = Directory(ReleaseRecord.releasesDir(dir));
    if (!root.existsSync()) return false;
    return root.listSync().whereType<Directory>().any(
      (d) => !p.basename(d.path).startsWith('.') && File(p.join(d.path, 'release.json')).existsSync(),
    );
  }
}

/// The server URL: setting (flag, environment, config file) first, then the URL recorded with
/// the release.
String resolveOpsServerUrl(CliContext ctx, ReleaseRecord? release) {
  final recorded = release?.registered?['server_url'] as String? ?? release?.serverUrl;
  final url = resolveServerUrl(ctx) ?? recorded;
  if (url == null || url.isEmpty) throw CliException(missingServerUrlMessage);
  return url;
}

/// An admin client for [url]. Throws with guidance when the admin key is missing.
AdminClient opsClient(CliContext ctx, String url) {
  final key = ctx.environment[adminKeyEnv];
  if (key == null || key.trim().isEmpty) throw CliException(missingAdminKeyMessage);
  return AdminClient(url, key.trim(), ctx.httpClientFactory());
}

/// "12.5" or "100" (no trailing ".0").
String formatPercent(Object? v) {
  if (v is! num) return '?';
  return v == v.roundToDouble() ? '${v.round()}' : '$v';
}

/// The channels a patch is deployed to, like `stable 100%, beta 10%`; `-` when none.
String channelsText(Map<String, Object?> patch) {
  final d = (patch['deployments'] as List? ?? const []).whereType<Map>().toList();
  if (d.isEmpty) return '-';
  return d.map((x) => '${x['channel']} ${formatPercent(x['rollout_percent'])}%').join(', ');
}

/// The patch number of a server patch.
int patchNumber(Map<String, Object?> patch) => (patch['number'] as num?)?.toInt() ?? 0;
