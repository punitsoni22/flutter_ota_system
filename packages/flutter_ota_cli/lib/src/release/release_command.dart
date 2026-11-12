// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../context.dart';
import '../keys/key_store.dart';
import 'android_release.dart';

/// `flutter_ota release`.
class ReleaseCommand extends Command<int> {
  ReleaseCommand(CliContext ctx) {
    addSubcommand(_ReleaseAndroid(ctx));
  }

  @override
  String get name => 'release';
  @override
  String get description => 'Build a store release with the OTA toolchain and register it with the server.';
}

class _ReleaseAndroid extends Command<int> {
  _ReleaseAndroid(this.ctx) {
    argParser
      ..addOption('kind', allowed: ['aab', 'apk'], defaultsTo: 'aab', help: 'Store bundle (aab) or APK.')
      ..addOption('build-name', help: 'Version name (default: pubspec.yaml version before "+").')
      ..addOption('build-number', help: 'Build number (default: pubspec.yaml version after "+").')
      ..addOption(
        'environment',
        defaultsTo: defaultEnvironment,
        help: 'Trust environment compiled into the app; patch signer certificates must match it.',
      )
      ..addOption('channel', help: 'Update channel compiled into the app (default in the SDK: production).')
      ..addOption('server-url', help: 'Override the configured server URL for this run.');
  }

  final CliContext ctx;

  @override
  String get name => 'android';
  @override
  String get description =>
      'Build an Android arm64 release (aab or apk), keep its local baseline in .flutter_ota/releases/, '
      'and register it (libapp.so only) with the server.';
  @override
  String get invocation => 'flutter_ota release android [options] [-- <extra flutter build arguments>]';

  @override
  Future<int> run() async {
    final r = argResults!;
    final result = await AndroidRelease(
      ctx,
      AndroidReleaseOptions(
        kind: r['kind'] as String,
        buildName: r['build-name'] as String?,
        buildNumber: r['build-number'] as String?,
        environment: r['environment'] as String,
        serverUrl: r['server-url'] as String?,
        channel: r['channel'] as String?,
        extraArgs: r.rest,
      ),
    ).run();
    final dir = ctx.workingDirectory;
    ctx.out.writeln('''

Release ${result.releaseId} is registered.
  Store file to upload to Google Play: ${p.relative(result.artifactPath, from: dir)}
  Local baseline (needed for patches): ${p.relative(result.releaseDir, from: dir)}
  libapp.so sha256: ${result.record['libapp_sha256']}
Keep the baseline folder (back it up, for example as a CI artifact): patches for this release
are built against its link.dill.''');
    return 0;
  }
}
