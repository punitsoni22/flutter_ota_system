// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:args/command_runner.dart';

import '../context.dart';
import '../errors.dart';
import 'android_build_versions.dart';
import '../keys/key_store.dart';
import '../project/lockfile.dart';
import '../project/project.dart';
import '../release/app_project.dart';
import '../server/admin_client.dart';
import '../server/app_state.dart';
import '../toolchain/manager.dart';

enum _Status { ok, warning, error, skipped }

class _Line {
  _Line(this.status, this.name, this.detail, [this.fix]);
  final _Status status;
  final String name;
  final String detail;
  final String? fix;
}

/// `flutter_ota doctor`: checks everything `release android` needs, with a fix for each problem.
class DoctorCommand extends Command<int> {
  DoctorCommand(this.ctx) {
    argParser
      ..addOption('environment', defaultsTo: defaultEnvironment, help: 'Trust environment to check signer keys for.')
      ..addOption('server-url', help: 'Override the configured server URL for this run.');
  }

  final CliContext ctx;

  @override
  String get name => 'doctor';
  @override
  String get description => 'Check the project, toolchain, server, admin key and signing keys before a release.';

  @override
  Future<int> run() async {
    final lines = <_Line>[];
    void add(_Status s, String n, String d, [String? fix]) => lines.add(_Line(s, n, d, fix));
    final environment = argResults!['environment'] as String;

    add(
      Platform.isLinux ? _Status.ok : _Status.error,
      'host',
      Platform.isLinux ? 'Linux' : '${Platform.operatingSystem} (only Linux x64 hosts are supported)',
    );

    // Project.
    String? dir;
    String? appId;
    final found = findProjectDir(ctx.workingDirectory);
    if (found == null) {
      add(_Status.error, projectFileName, 'not found', 'flutter_ota init --app-id <server application UUID>');
    } else {
      dir = found;
      try {
        appId = readAppId(found);
        add(_Status.ok, projectFileName, 'app_id $appId');
      } on CliException catch (e) {
        add(_Status.error, projectFileName, e.message);
      }
    }
    AppProject? app;
    if (dir != null) {
      try {
        app = AppProject.inspect(dir);
        add(
          app.isFlutterApp ? _Status.ok : _Status.error,
          'flutter app',
          app.isFlutterApp ? app.packageName : 'pubspec.yaml has no `flutter: sdk: flutter` dependency',
        );
        add(
          app.hasAndroid ? _Status.ok : _Status.error,
          'android project',
          app.hasAndroid ? 'android/app' : 'missing',
          'flutter create --platforms=android .  (with your normal Flutter, once)',
        );
        add(
          app.dependsOnSdk ? _Status.ok : _Status.error,
          'SDK dependency',
          app.dependsOnSdk ? sdkPackageName : 'pubspec.yaml does not depend on $sdkPackageName',
          'add `$sdkPackageName` to dependencies in pubspec.yaml',
        );
        add(
          app.mainCallsInitialize ? _Status.ok : _Status.warning,
          'FlutterOta.initialize',
          app.mainCallsInitialize ? 'called in lib/main.dart' : 'not found in lib/main.dart (simple text check)',
          'call `await FlutterOta.initialize();` in main() before runApp()',
        );
        if (app.gitIgnoresWholeWorkDir) {
          add(
            _Status.warning,
            '.gitignore',
            'all of $otaWorkDirName/ is ignored, so $otaWorkDirName/packages/ (used by pubspec.yaml) is not committed',
            'ignore only `/$otaWorkDirName/releases/` and commit $otaWorkDirName/packages/',
          );
        } else {
          add(
            app.gitIgnoresWorkDir ? _Status.ok : _Status.warning,
            '.gitignore',
            app.gitIgnoresWorkDir
                ? '$otaWorkDirName/releases/ is ignored'
                : '$otaWorkDirName/releases/ is not in .gitignore',
            'add the line `/$otaWorkDirName/releases/` to .gitignore (back up release folders separately)',
          );
        }
      } on CliException catch (e) {
        add(_Status.error, 'pubspec.yaml', e.message);
      }
    }

    // Toolchain.
    if (dir != null) {
      Lockfile? lock;
      try {
        lock = Lockfile.readIn(dir);
      } on CliException catch (e) {
        add(_Status.error, lockFileName, e.message);
      }
      if (lock == null) {
        if (!lines.any((l) => l.name == lockFileName)) {
          add(_Status.error, lockFileName, 'missing', 'flutter_ota toolchain install');
        }
      } else {
        add(_Status.ok, lockFileName, '${lock.toolchain} (Flutter ${lock.flutter})');
        final min = minimumsFor(lock.flutter);
        if (min != null) {
          final problems = AndroidBuildVersions.read(dir).problemsAgainst(min);
          if (problems.isEmpty) {
            add(_Status.ok, 'android build tools', 'meet the Flutter ${lock.flutter} minimums');
          } else {
            add(
              _Status.error,
              'android build tools',
              '${problems.join(', ')} (Flutter ${lock.flutter} refuses to build below these)',
              'raise them in android/gradle/wrapper/gradle-wrapper.properties and android/settings.gradle(.kts)',
            );
          }
        }
        try {
          final tc = await ToolchainManager(ctx).resolve(lock);
          add(_Status.ok, 'toolchain', 'installed and verified (${tc.root})');
        } on CliException catch (e) {
          add(_Status.error, 'toolchain', e.message.split('\n').first, 'flutter_ota toolchain install');
        }
      }
    }

    // Server, admin key, app, keys.
    String? url;
    try {
      url = resolveServerUrl(ctx, flag: argResults!['server-url'] as String?);
    } on CliException catch (e) {
      add(_Status.error, 'server URL', e.message);
    }
    final adminKey = ctx.environment[adminKeyEnv];
    final hasKey = adminKey != null && adminKey.trim().isNotEmpty;
    if (url == null) {
      if (!lines.any((l) => l.name == 'server URL')) {
        add(_Status.error, 'server URL', 'not set', 'flutter_ota config set server-url https://ota.example.com');
      }
    } else {
      add(_Status.ok, 'server URL', url);
    }
    add(
      hasKey ? _Status.ok : _Status.error,
      'admin key',
      hasKey ? '$adminKeyEnv is set (never stored by flutter_ota)' : '$adminKeyEnv is not set',
      'read -rs $adminKeyEnv && export $adminKeyEnv',
    );
    if (url != null) {
      final client = AdminClient(url, hasKey ? adminKey.trim() : '', ctx.httpClientFactory());
      try {
        final h = await client.health();
        add(
          h == null ? _Status.ok : _Status.error,
          'server reachable',
          h ?? 'GET /health/live ok',
          'check the URL and that the server runs',
        );
        if (h == null && hasKey && appId != null) {
          try {
            final state = await fetchAppState(client, appId);
            add(_Status.ok, 'app on server', 'slug ${state.slug}');
            final store = AppKeyStore.forApp(ctx.environment, appId);
            try {
              final sel = selectRootKeys(store.rootPublicKeys(), state);
              add(
                sel.warnings.isEmpty ? _Status.ok : _Status.warning,
                'root keys',
                '${sel.embedded.keys.join(', ')} registered${sel.warnings.isEmpty ? '' : '; ${sel.warnings.join(' ')}'}',
              );
            } on CliException catch (e) {
              add(_Status.error, 'root keys', e.message.split('\n').first, 'flutter_ota keys init');
            }
            final signer = store.activeSigner(environment, DateTime.now());
            final onServer = signer != null && state.certificates.any((c) => c['serial'] == signer.serial);
            add(
              onServer ? _Status.ok : _Status.warning,
              'signer key',
              signer == null
                  ? 'no valid signer certificate for "$environment" on this machine (needed for patches)'
                  : onServer
                  ? '${signer.keyId} (serial ${signer.serial}) valid until ${signer.body['not_after']}'
                  : '${signer.keyId} is not registered on the server',
              'flutter_ota keys init${environment == defaultEnvironment ? '' : ' --environment $environment'}',
            );
          } on ServerException catch (e) {
            add(_Status.error, 'app on server', e.message);
          } on CliException catch (e) {
            add(_Status.error, 'app on server', e.message.split('\n').first, 'check app_id: `ota app list`');
          }
        } else if (!hasKey || appId == null) {
          add(_Status.skipped, 'app on server', 'needs the admin key and a valid app_id');
        }
      } finally {
        client.close();
      }
    }

    var failed = false;
    for (final l in lines) {
      final mark = switch (l.status) {
        _Status.ok => '[ok]',
        _Status.warning => '[!] ',
        _Status.error => '[x] ',
        _Status.skipped => '[-] ',
      };
      ctx.out.writeln('$mark ${l.name}: ${l.detail}');
      if (l.fix != null && (l.status == _Status.error || l.status == _Status.warning)) {
        ctx.out.writeln('       fix: ${l.fix}');
      }
      if (l.status == _Status.error) failed = true;
    }
    ctx.out.writeln(
      failed
          ? '\nSome checks failed. Fix them before `flutter_ota release android`.'
          : '\nReady for `flutter_ota release android`.',
    );
    return failed ? 1 : 0;
  }
}
