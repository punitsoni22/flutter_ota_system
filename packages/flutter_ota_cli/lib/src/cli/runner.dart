// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config/user_config.dart';
import '../context.dart';
import '../doctor/doctor_command.dart';
import '../errors.dart';
import '../features/commands.dart';
import '../keys/keys_command.dart';
import '../ops/rollback_command.dart';
import '../ops/status_command.dart';
import '../patch/commands.dart';
import '../release/release_command.dart';
import '../project/lockfile.dart';
import '../project/project.dart';
import '../toolchain/cache.dart';
import '../toolchain/disk_space.dart';
import '../toolchain/index.dart';
import '../toolchain/install_lock.dart';
import '../toolchain/manager.dart';
import '../toolchain/selection.dart';
import '../doctor/android_build_versions.dart';
import '../toolchain/trusted_keys.dart';
import '../version.dart';

/// Runs the `flutter_ota` CLI and returns the process exit code.
Future<int> runCli(List<String> args, {CliContext? context}) async {
  final ctx = context ?? CliContext();
  final runner =
      CommandRunner<int>(
          'flutter_ota',
          'Flutter OTA System developer CLI (experimental alpha; Linux x64 hosts, Android arm64 apps).',
        )
        ..argParser.addFlag('version', negatable: false, help: 'Print the CLI version.')
        ..addCommand(_InitCommand(ctx))
        ..addCommand(_ConfigCommand(ctx))
        ..addCommand(_ToolchainCommand(ctx))
        ..addCommand(_UpgradeCommand(ctx))
        ..addCommand(DoctorCommand(ctx))
        ..addCommand(KeysCommand(ctx))
        ..addCommand(ReleaseCommand(ctx))
        ..addCommand(FeaturesCommand(ctx))
        ..addCommand(PatchCommand(ctx))
        ..addCommand(StatusCommand(ctx))
        ..addCommand(RollbackCommand(ctx));
  try {
    final parsed = runner.parse(args);
    if (parsed['version'] == true) {
      ctx.out.writeln('flutter_ota $cliVersion');
      return 0;
    }
    return await runner.runCommand(parsed) ?? 0;
  } on UsageException catch (e) {
    ctx.err.writeln(e);
    return 64;
  } on CliException catch (e) {
    ctx.err.writeln('error: ${e.message}');
    return e.exitCode;
  }
}

abstract class _Cmd extends Command<int> {
  _Cmd(this.ctx);
  final CliContext ctx;

  String get cwd => ctx.workingDirectory;

  bool confirm(String question, {required bool yes}) {
    if (yes) return true;
    final answer = ctx.prompt('$question [y/N] ');
    if (answer == null) {
      throw CliException('Confirmation needed, but there is no interactive terminal. Re-run with --yes.');
    }
    return const {'y', 'yes'}.contains(answer.trim().toLowerCase());
  }
}

// ---------------------------------------------------------------- init

class _InitCommand extends _Cmd {
  _InitCommand(super.ctx) {
    argParser
      ..addOption('app-id', help: 'Server application UUID ("id" from `ota app list`).')
      ..addFlag('force', negatable: false, help: 'Overwrite an existing flutter_ota.yaml.');
  }

  @override
  String get name => 'init';
  @override
  String get description => 'Create flutter_ota.yaml (it contains only app_id) in the current Flutter project.';

  @override
  Future<int> run() async {
    final file = File(p.join(cwd, projectFileName));
    if (file.existsSync() && argResults!['force'] != true) {
      throw CliException('${file.path} already exists. Use --force to overwrite it.');
    }
    var raw = argResults!['app-id'] as String?;
    if (raw == null) {
      raw = ctx.prompt('Server application UUID (the "id" from `ota app list`): ');
      if (raw == null) throw CliException('Pass the application UUID with --app-id <uuid>.');
    }
    final appId = validateAppId(raw);
    if (!File(p.join(cwd, 'pubspec.yaml')).existsSync()) {
      ctx.log('warning: no pubspec.yaml here; run init in the root of your Flutter app.');
    }
    file.writeAsStringSync(projectFileContent(appId));
    ctx.out.writeln('Wrote ${file.path}');
    ctx.out.writeln('''
Next steps:
  1. Set your server once:     flutter_ota config set server-url https://ota.example.com
  2. Install the toolchain:    flutter_ota toolchain install
  3. Add the SDK:              flutter pub add flutter_ota_system
     and call `await FlutterOta.initialize();` in main() (see the quick start, step 6).
  4. Create your signing keys:  flutter_ota keys init''');
    return 0;
  }
}

// ---------------------------------------------------------------- config

class _ConfigCommand extends _Cmd {
  _ConfigCommand(super.ctx) {
    addSubcommand(_ConfigSet(ctx));
    addSubcommand(_ConfigGet(ctx));
    addSubcommand(_ConfigList(ctx));
    addSubcommand(_ConfigUnset(ctx));
    addSubcommand(_ConfigAddKey(ctx));
    addSubcommand(_ConfigRemoveKey(ctx));
  }
  @override
  String get name => 'config';
  @override
  String get description => 'Read or change user settings (~/.config/flutter_ota/config.yaml).';
}

class _ConfigSet extends _Cmd {
  _ConfigSet(super.ctx);
  @override
  String get name => 'set';
  @override
  String get description => 'Set a value: ${configKeys.keys.join(', ')}.';
  @override
  String get invocation => 'flutter_ota config set <key> <value>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 2) usageException('Expected <key> <value>.');
    final cfg = UserConfig.load(ctx.environment);
    cfg.set(rest[0], rest[1]);
    ctx.out.writeln('${rest[0]} = ${cfg.values[rest[0]]}  (saved in ${cfg.path})');
    final envName = configEnv[rest[0]];
    if (envName != null && (ctx.environment[envName] ?? '').isNotEmpty) {
      ctx.log('note: $envName is set in your environment and overrides this value.');
    }
    return 0;
  }
}

class _ConfigUnset extends _Cmd {
  _ConfigUnset(super.ctx);
  @override
  String get name => 'unset';
  @override
  String get description => 'Remove a value from the config file.';
  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('Expected <key>.');
    UserConfig.load(ctx.environment).unset(rest[0]);
    return 0;
  }
}

String _sourceLabel(ConfigSource s, String key) => switch (s) {
  ConfigSource.flag => 'command line',
  ConfigSource.environment => 'environment ${configEnv[key]}',
  ConfigSource.file => 'config file',
  ConfigSource.builtIn => 'built-in default',
  ConfigSource.unset => 'not set',
};

class _ConfigGet extends _Cmd {
  _ConfigGet(super.ctx);
  @override
  String get name => 'get';
  @override
  String get description => 'Print the effective value of a setting (flag > environment > config file).';
  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('Expected <key>.');
    if (!configKeys.containsKey(rest[0])) throw CliException('Unknown setting "${rest[0]}".');
    final v = UserConfig.load(ctx.environment).resolve(rest[0], ctx.environment, builtIn: _builtInDefaults[rest[0]]);
    if (v.value == null) {
      ctx.err.writeln('${rest[0]} is not set.');
      return 1;
    }
    ctx.out.writeln(v.value);
    return 0;
  }
}

/// Built-in values used when a setting is not set by flag, environment or config file.
const _builtInDefaults = <String, String>{'toolchain-index-url': defaultToolchainIndexUrl};

class _ConfigList extends _Cmd {
  _ConfigList(super.ctx);
  @override
  String get name => 'list';
  @override
  String get description => 'List all settings with where each value comes from.';
  @override
  Future<int> run() async {
    final cfg = UserConfig.load(ctx.environment);
    ctx.out.writeln('Config file: ${cfg.path}');
    for (final k in configKeys.keys) {
      final v = cfg.resolve(k, ctx.environment, builtIn: _builtInDefaults[k]);
      ctx.out.writeln('$k = ${v.value ?? '(not set)'}  [${_sourceLabel(v.source, k)}]');
    }
    final keys = {...cfg.toolchainKeys};
    ctx.out.writeln('toolchain-trusted-keys (built-in): ${embeddedToolchainKeys.keys.join(', ')}');
    ctx.out.writeln('toolchain-trusted-keys (user-added): ${keys.isEmpty ? '(none)' : keys.keys.join(', ')}');
    return 0;
  }
}

class _ConfigAddKey extends _Cmd {
  _ConfigAddKey(super.ctx);
  @override
  String get name => 'add-toolchain-key';
  @override
  String get description => 'Trust a toolchain-signing PUBLIC key (for self-built toolchains or mirrors).';
  @override
  String get invocation => 'flutter_ota config add-toolchain-key <key_id> <public_key_base64>';
  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 2) usageException('Expected <key_id> <public_key_base64>.');
    UserConfig.load(ctx.environment).addToolchainKey(rest[0], rest[1]);
    ctx.out.writeln('Trusting toolchain key ${rest[0]}.');
    return 0;
  }
}

class _ConfigRemoveKey extends _Cmd {
  _ConfigRemoveKey(super.ctx);
  @override
  String get name => 'remove-toolchain-key';
  @override
  String get description => 'Stop trusting a user-added toolchain key.';
  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('Expected <key_id>.');
    if (!UserConfig.load(ctx.environment).removeToolchainKey(rest[0])) {
      throw CliException('Key ${rest[0]} is not in your config.');
    }
    return 0;
  }
}

// ---------------------------------------------------------------- toolchain

class _ToolchainCommand extends _Cmd {
  _ToolchainCommand(super.ctx) {
    addSubcommand(_ToolchainList(ctx));
    addSubcommand(_ToolchainInstall(ctx));
    addSubcommand(_ToolchainDoctor(ctx));
    addSubcommand(_ToolchainClean(ctx));
  }
  @override
  String get name => 'toolchain';
  @override
  String get description => 'Manage the pinned OTA toolchain (a stock Flutter SDK plus our signed overlay).';
}

class _ToolchainList extends _Cmd {
  _ToolchainList(super.ctx) {
    argParser.addFlag('offline', negatable: false, help: 'Only list installed toolchains.');
  }
  @override
  String get name => 'list';
  @override
  String get description => 'List installed and available toolchains (* = pinned by this project).';
  @override
  Future<int> run() async {
    final m = ToolchainManager(ctx);
    final projectDir = findProjectDir(cwd);
    final lock = projectDir == null ? null : Lockfile.readIn(projectDir);
    final installed = m.installed();
    ctx.out.writeln('Installed (${m.cache.toolchains}):');
    if (installed.isEmpty) ctx.out.writeln('  (none)');
    for (final e in installed.entries) {
      final pin = lock?.toolchain == e.key ? '*' : ' ';
      ctx.out.writeln(
        '$pin ${e.key}  flutter ${e.value['flutter']}  dart ${e.value['dart']}  '
        'engine ${(e.value['engine'] as String).substring(0, 8)}',
      );
    }
    if (argResults!['offline'] == true) return 0;
    final index = await m.loadIndex();
    ctx.out.writeln('Available (${index.source}, signed by ${index.signedBy}):');
    for (final t in index.toolchains) {
      final pin = lock?.toolchain == t.id ? '*' : ' ';
      final state = installed.containsKey(t.id) ? 'installed' : 'not installed';
      final host = t.host == supportedHost ? '' : '  [${t.host}: not usable on this host]';
      ctx.out.writeln(
        '$pin ${t.id}  flutter ${t.flutter}  dart ${t.dart}  $state  '
        'download ${formatBytes(t.sdk.size + t.overlay.size)}$host',
      );
    }
    if (lock != null && index.byId(lock.toolchain) == null) {
      ctx.log('warning: the pinned toolchain ${lock.toolchain} is no longer listed in the index.');
    }
    return 0;
  }
}

class _ToolchainInstall extends _Cmd {
  _ToolchainInstall(super.ctx) {
    argParser.addFlag('force', negatable: false, help: 'Reinstall even if already installed.');
  }
  @override
  String get name => 'install';
  @override
  String get description =>
      'Install the toolchain pinned in flutter_ota.lock (or [id]). '
      'In a project without a lock, pins the installed toolchain.';
  @override
  String get invocation => 'flutter_ota toolchain install [id]';

  @override
  Future<int> run() async {
    final m = ToolchainManager(ctx);
    final projectDir = findProjectDir(cwd);
    final lock = projectDir == null ? null : Lockfile.readIn(projectDir);
    final rest = argResults!.rest;
    final requested = rest.isEmpty ? null : rest.single;
    if (lock != null && requested != null && requested != lock.toolchain) {
      throw CliException(
        'This project is pinned to ${lock.toolchain} in $lockFileName. '
        'To change it, run:  flutter_ota upgrade --to $requested',
      );
    }
    final index = await m.loadIndex();
    final ToolchainEntry entry;
    final id = requested ?? lock?.toolchain;
    if (id != null) {
      final e = index.byId(id);
      if (e == null) throw CliException('Toolchain $id is not in the verified index (${index.source}).');
      if (lock != null && !lock.matches(e)) {
        throw CliException(
          'The index entry for $id does not match $lockFileName (different hashes). '
          'Refusing to install it; ask the toolchain publisher.',
        );
      }
      entry = e;
    } else {
      final compatible = index.compatible;
      if (compatible.isEmpty) throw CliException('The index lists no toolchain for $supportedHost hosts.');
      // No pin yet: the newest toolchain this project can build with (Dart constraint, Android
      // build tool minimums).
      final choice = chooseToolchain(compatible, projectDir: projectDir);
      for (final s in choice.skipped) {
        ctx.out.writeln('Skipping $s');
      }
      if (choice.entry == null) {
        throw CliException(
          'No toolchain in the index fits this project. Raise the Android build tool versions or the '
          'pubspec.yaml sdk constraint, or name a toolchain:  flutter_ota toolchain install <id>',
        );
      }
      entry = choice.entry!;
    }
    await m.install(entry, force: argResults!['force'] == true);
    if (projectDir != null && lock == null) {
      Lockfile.fromEntry(entry).writeTo(projectDir);
      ctx.out.writeln('Pinned ${entry.id} in ${p.join(projectDir, lockFileName)}');
    }
    if (projectDir != null) m.recordProjectUse(p.join(projectDir, lockFileName), entry.id);
    ctx.out.writeln('Toolchain ${entry.id} is ready.');
    return 0;
  }
}

class _ToolchainDoctor extends _Cmd {
  _ToolchainDoctor(super.ctx);
  @override
  String get name => 'doctor';
  @override
  String get description => 'Check installed toolchains (hashes, overlay, mirror, tools, disk space).';
  @override
  String get invocation => 'flutter_ota toolchain doctor [id]';

  @override
  Future<int> run() async {
    final m = ToolchainManager(ctx);
    final rest = argResults!.rest;
    final projectDir = findProjectDir(cwd);
    final lock = projectDir == null ? null : Lockfile.readIn(projectDir);
    final ids = rest.isNotEmpty
        ? rest
        : lock != null
        ? [lock.toolchain]
        : m.installed().keys.toList();
    if (ids.isEmpty) {
      ctx.out.writeln('No toolchain installed. Run: flutter_ota toolchain install');
      return 1;
    }
    var failed = false;
    if (Platform.isLinux == false) {
      ctx.out.writeln('[x] host: toolchains are built for linux-x64 only');
      failed = true;
    }
    for (final id in ids) {
      ctx.out.writeln('Toolchain $id${lock?.toolchain == id ? ' (pinned by $lockFileName)' : ''}');
      for (final c in await m.doctor(id)) {
        final mark = !c.ok ? '[x]' : (c.warning ? '[!]' : '[ok]');
        ctx.out.writeln('  $mark ${c.name}: ${c.detail}');
        if (!c.ok) failed = true;
      }
    }
    return failed ? 1 : 0;
  }
}

class _ToolchainClean extends _Cmd {
  _ToolchainClean(super.ctx) {
    argParser
      ..addFlag('unused', negatable: false, help: 'Also remove toolchains no known project pins.')
      ..addFlag('all', negatable: false, help: 'Remove every installed toolchain (asks first).')
      ..addFlag('yes', abbr: 'y', negatable: false, help: 'Do not ask for confirmation.');
  }
  @override
  String get name => 'clean';
  @override
  String get description => 'Remove downloaded archives and leftovers; --unused / --all also remove toolchains.';

  @override
  Future<int> run() async {
    final m = ToolchainManager(ctx);
    final c = m.cache;
    var freed = 0;
    int sizeOf(FileSystemEntity e) {
      if (e is File) return e.lengthSync();
      if (e is Directory) {
        return e.listSync(recursive: true, followLinks: false).whereType<File>().fold(0, (a, f) => a + f.lengthSync());
      }
      return 0;
    }

    void remove(FileSystemEntity e) {
      freed += sizeOf(e);
      e.deleteSync(recursive: true);
    }

    // Downloads (verified archives and partial files): never needed after install.
    final dl = Directory(c.downloads);
    if (dl.existsSync()) {
      for (final f in dl.listSync()) {
        final name = p.basename(f.path);
        // Keep partial files that an install in progress is writing.
        if (name.endsWith('.part') && _anyLockHeld(c)) continue;
        remove(f);
      }
    }
    // Leftover temp dirs of dead installs, and stale lock files.
    final tc = Directory(c.toolchains);
    if (tc.existsSync()) {
      for (final d in tc.listSync().whereType<Directory>()) {
        final m2 = RegExp(r'^\.tmp-.+-(\d+)-\d+$').firstMatch(p.basename(d.path));
        if (m2 != null && !processAlive(int.parse(m2.group(1)!))) remove(d);
      }
    }
    final unused = argResults!['unused'] == true;
    final all = argResults!['all'] == true;
    if (unused || all) {
      final pinned = all ? <String>{} : m.pinnedToolchains();
      final victims = m.installed().keys.where((id) => !pinned.contains(id)).toList()..sort();
      final projectDir = findProjectDir(cwd);
      final currentLock = projectDir == null ? null : Lockfile.readIn(projectDir);
      if (victims.isNotEmpty) {
        ctx.out.writeln('Toolchains to remove: ${victims.join(', ')}');
        if (currentLock != null && victims.contains(currentLock.toolchain)) {
          ctx.out.writeln('  (includes ${currentLock.toolchain}, pinned by this project)');
        }
        if (!confirm('Remove them?', yes: argResults!['yes'] == true)) {
          ctx.out.writeln('Nothing removed.');
          return 1;
        }
        for (final id in victims) {
          final lockF = File(c.lockFile(id));
          if (lockF.existsSync()) {
            ctx.log('Skipping $id: an install is in progress.');
            continue;
          }
          remove(Directory(c.toolchainDir(id)));
        }
      }
    }
    ctx.out.writeln('Freed ${formatBytes(freed)}.');
    return 0;
  }

  bool _anyLockHeld(CachePaths c) {
    final d = Directory(c.locks);
    if (!d.existsSync()) return false;
    return d.listSync().whereType<File>().any((f) {
      final owner = int.tryParse(f.readAsStringSync().trim());
      return owner != null && processAlive(owner);
    });
  }
}

// ---------------------------------------------------------------- upgrade

class _UpgradeCommand extends _Cmd {
  _UpgradeCommand(super.ctx) {
    argParser
      ..addOption('to', help: 'Toolchain id to move to (default: the newest compatible one).')
      ..addFlag('yes', abbr: 'y', negatable: false, help: 'Do not ask for confirmation (for CI).');
  }
  @override
  String get name => 'upgrade';
  @override
  String get description =>
      'Move this project to another toolchain: shows the change, asks, installs, '
      'then rewrites flutter_ota.lock.';

  @override
  Future<int> run() async {
    final projectDir = findProjectDir(cwd);
    if (projectDir == null) throw CliException('No $projectFileName found. Run `flutter_ota init` first.');
    final lock = Lockfile.readIn(projectDir);
    final m = ToolchainManager(ctx);
    final index = await m.loadIndex();
    final compatible = index.compatible;
    ctx.out.writeln(
      'Current: ${lock == null ? '(no $lockFileName yet)' : '${lock.toolchain} (Flutter ${lock.flutter})'}',
    );
    ctx.out.writeln('Compatible toolchains in the verified index:');
    for (final t in compatible) {
      ctx.out.writeln('  ${t.id == lock?.toolchain ? '*' : ' '} ${t.id}  flutter ${t.flutter}  dart ${t.dart}');
    }
    final to = argResults!['to'] as String?;
    final ToolchainEntry target;
    if (to != null) {
      final e = index.byId(to);
      if (e == null || e.host != supportedHost) throw CliException('Toolchain $to is not available for this host.');
      target = e;
    } else {
      if (compatible.isEmpty) throw CliException('No compatible toolchain in the index.');
      // Default: the newest toolchain this project can build with; say why newer ones do not fit.
      final choice = chooseToolchain(compatible, projectDir: projectDir);
      for (final s in choice.skipped) {
        ctx.out.writeln('Not offered: $s');
      }
      if (choice.entry == null) throw CliException('No toolchain in the index fits this project.');
      target = choice.entry!;
    }
    final min = minimumsFor(target.flutter);
    final problems = min == null ? const <String>[] : AndroidBuildVersions.read(projectDir).problemsAgainst(min);
    if (problems.isNotEmpty) {
      ctx.out.writeln(
        'Warning: Flutter ${target.flutter} refuses to build this project until you raise ${problems.join(', ')} '
        '(android/gradle/wrapper/gradle-wrapper.properties, android/settings.gradle(.kts)).',
      );
    }
    if (lock != null && lock.matches(target)) {
      ctx.out.writeln('Already on ${target.id}. Nothing to do.');
      return 0;
    }
    ctx.out.writeln(
      '\nChange: ${lock?.toolchain ?? '(none)'} -> ${target.id} '
      '(Flutter ${lock?.flutter ?? '-'} -> ${target.flutter}, Dart ${lock?.dart ?? '-'} -> ${target.dart})',
    );
    ctx.out.writeln(
      'A new toolchain means a new store release: patches only apply to apps built with the same '
      'toolchain.',
    );
    if (!confirm('Install ${target.id} and update $lockFileName?', yes: argResults!['yes'] == true)) {
      ctx.out.writeln('Cancelled. $lockFileName was not changed.');
      return 1;
    }
    await m.install(target);
    Lockfile.fromEntry(target).writeTo(projectDir);
    m.recordProjectUse(p.join(projectDir, lockFileName), target.id);
    ctx.out.writeln('Updated ${p.join(projectDir, lockFileName)} to ${target.id}.');
    return 0;
  }
}
