// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import '../errors.dart';
import 'admin_client.dart';

/// What the server knows about one app (looked up by its UUID).
class ServerAppState {
  ServerAppState(this.appId, this.slug, this.activeRoots, this.revokedRoots, this.certificates);

  final String appId;

  /// The release routes of the backend address apps by slug.
  final String slug;

  /// Registered, non-revoked root keys: key id -> public key.
  final Map<String, String> activeRoots;
  final Set<String> revokedRoots;
  final List<Map<String, Object?>> certificates;
}

/// Loads the app and its trust state. Throws [CliException] with guidance when the app is
/// unknown to the server.
Future<ServerAppState> fetchAppState(AdminClient c, String appId) async {
  final app = await c.findApp(appId);
  if (app == null) {
    throw CliException(
      'The server ${c.baseUrl} has no application with id $appId (the app_id in flutter_ota.yaml).\n'
      'List the apps with `ota app list` and copy the "id" of yours, or create the app first.',
    );
  }
  final trust = await c.trust(appId);
  final active = <String, String>{};
  final revoked = <String>{};
  for (final r in ((trust['roots'] as List?) ?? const []).cast<Map<String, Object?>>()) {
    if (r['revoked_at'] == null) {
      active[r['key_id'] as String] = r['public_key'] as String;
    } else {
      revoked.add(r['key_id'] as String);
    }
  }
  return ServerAppState(
    appId,
    app['slug'] as String,
    active,
    revoked,
    ((trust['certificates'] as List?) ?? const []).cast<Map<String, Object?>>(),
  );
}

/// Result of matching local root keys with the server.
class RootKeySelection {
  RootKeySelection(this.embedded, this.warnings);

  /// Roots compiled into the app: present locally AND registered (same key, not revoked).
  final Map<String, String> embedded;
  final List<String> warnings;
}

/// The root public keys a build may embed. Only keys the developer holds locally and that the
/// server has registered (same public key, not revoked) are used: a key that only the server
/// lists is never compiled into an app, so a compromised server cannot add its own root.
RootKeySelection selectRootKeys(Map<String, String> local, ServerAppState server) {
  final warnings = <String>[];
  if (local.isEmpty) {
    throw CliException(
      'This machine has no root key for app ${server.appId}.\n'
      'Create and register the app keys once with:  flutter_ota keys init\n'
      '(If a teammate created them, copy the public roots/*.pub files into your keys folder.)',
    );
  }
  final embedded = <String, String>{};
  for (final e in local.entries) {
    final remote = server.activeRoots[e.key];
    if (remote == null) {
      warnings.add(
        server.revokedRoots.contains(e.key)
            ? 'Root key ${e.key} is revoked on the server; it is not compiled into this build.'
            : 'Root key ${e.key} is not registered on the server; run `flutter_ota keys init` to register it.',
      );
    } else if (remote != e.value) {
      throw CliException(
        'Root key ${e.key} on the server is a DIFFERENT public key than the one on this machine.\n'
        'Stop and check who registered it. The build was not started.',
      );
    } else {
      embedded[e.key] = e.value;
    }
  }
  for (final id in server.activeRoots.keys) {
    if (!local.containsKey(id)) {
      warnings.add('The server lists root key $id, which is not on this machine; it is not compiled into the app.');
    }
  }
  if (embedded.isEmpty) {
    throw CliException(
      'None of the root keys on this machine is registered on the server.\n'
      'Register them with:  flutter_ota keys init',
    );
  }
  return RootKeySelection(embedded, warnings);
}
