// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../build_support/toolchain_build.dart';
import '../context.dart';
import '../errors.dart';
import '../project/lockfile.dart';
import '../project/project.dart';
import '../toolchain/manager.dart';
import 'module_builder.dart';
import 'release_record.dart';
import 'pipeline.dart';

/// Environment variable with the path of a `bc_verify` AOT snapshot, used ONLY when the toolchain
/// does not ship [ResolvedToolchain.bcVerifySnapshot] (overlays built before it was bundled).
const bcVerifyEnv = 'FLUTTER_OTA_BC_VERIFY';

/// `flutter_ota patch <platform>`.
class PatchCommand extends Command<int> {
  PatchCommand(CliContext ctx) {
    addSubcommand(PatchAndroidCommand(ctx));
  }
  @override
  String get name => 'patch';
  @override
  String get description => 'Build, sign and upload a patch for a store release.';
}

class PatchAndroidCommand extends Command<int> {
  PatchAndroidCommand(this.ctx) {
    argParser
      ..addOption('release', help: 'Release id (UUID). Default: the newest local release.')
      ..addOption('channel', help: 'Publish to this channel after the upload (otherwise the patch stays a draft).')
      ..addOption('rollout', help: 'Percent of devices on the channel (0-100, default 100). Needs --channel.')
      ..addOption('note', defaultsTo: '', help: 'A note stored with the patch on the server.')
      ..addFlag('dry-run', negatable: false, help: 'Build, check and sign locally; print the summary; upload nothing.');
  }

  final CliContext ctx;

  @override
  String get name => 'android';
  @override
  String get description =>
      'Patch the changed feature packages of an Android store release (closure, codegen check, '
      'rename, guard, compile, verify, local signature, upload).';

  @override
  Future<int> run() async {
    final a = argResults!;
    final projectDir = findProjectDir(ctx.workingDirectory);
    if (projectDir == null) throw CliException('No $projectFileName found. Run `flutter_ota init` first.');
    int? rollout;
    if (a['rollout'] != null) {
      rollout = int.tryParse(a['rollout'] as String);
      if (rollout == null || rollout < 0 || rollout > 100) {
        usageException('--rollout must be a whole number from 0 to 100.');
      }
      if (a['channel'] == null) usageException('--rollout needs --channel.');
    }
    final lock = Lockfile.readIn(projectDir);
    if (lock == null) throw CliException('No $lockFileName in $projectDir. Run `flutter_ota toolchain install` first.');
    // A patch must be built with the toolchain its store release was built with (the installed app
    // only runs bytecode from that exact toolchain), even when the project has moved on to another one.
    final release = ReleaseRecord.find(projectDir, releaseId: a['release'] as String?);
    final m = ToolchainManager(ctx);
    final ResolvedToolchain tc;
    if (release.toolchainId == lock.toolchainId) {
      tc = await m.resolve(lock, lockPath: p.join(projectDir, lockFileName));
    } else {
      ctx.out.writeln(
        'Release ${release.releaseId} was built with ${release.toolchainName}; this project now pins '
        '${lock.toolchain}. Building the patch with ${release.toolchainName}.',
      );
      tc = await m.resolve(
        await releaseToolchainLock(
          m,
          releaseId: release.releaseId,
          toolchain: release.toolchainName,
          toolchainId: release.toolchainId,
        ),
      );
    }
    final tools = toolsFor(tc, ctx.environment);
    final pipeline = PatchPipeline(
      ctx: ctx,
      projectDir: projectDir,
      tools: tools,
      toolchainRoot: tc.root,
      toolchainId: tc.toolchainId,
      processEnvironment: toolchainProcessEnvironment(ctx.environment, tc),
    );
    await pipeline.execute(
      PatchOptions(
        releaseId: a['release'] as String?,
        channel: a['channel'] as String?,
        rolloutPercent: rollout,
        dryRun: a['dry-run'] == true,
        note: a['note'] as String,
      ),
    );
    return 0;
  }
}

/// The lock-like pin of the toolchain a store release was built with ([toolchain], [toolchainId]
/// from its release.json): from the install record when it is installed, otherwise from the
/// verified index (installing it). The index entry must carry the release's exact toolchain id, so
/// a mirror cannot swap in another toolchain.
Future<Lockfile> releaseToolchainLock(
  ToolchainManager m, {
  required String releaseId,
  required String toolchain,
  required String toolchainId,
}) async {
  final installed = m.installed()[toolchain];
  if (installed != null && installed['toolchain_id'] == toolchainId) {
    String f(String k) => '${installed[k] ?? ''}';
    return Lockfile(
      toolchain: toolchain,
      toolchainId: toolchainId,
      flutter: f('flutter'),
      dart: f('dart'),
      engine: f('engine'),
      dartRevision: f('dart_revision'),
    );
  }
  final index = await m.loadIndex();
  final entry = index.byId(toolchain);
  if (entry == null || entry.toolchainId != toolchainId) {
    throw CliException(
      'Release $releaseId was built with $toolchain ($toolchainId), which is not '
      'installed and not in the verified toolchain index (${index.source}). Patches for this release need that '
      'exact toolchain.',
    );
  }
  m.ctx.out.writeln('Installing ${entry.id} for release $releaseId...');
  await m.install(entry);
  return Lockfile.fromEntry(entry);
}

/// The patch tools of an installed toolchain.
///
/// The reference verifier is the toolchain's own [ResolvedToolchain.bcVerifySnapshot]; the
/// [bcVerifyEnv] override is used only when that snapshot is missing. When neither exists,
/// [PatchTools.bcVerify] is null and the pipeline refuses to upload (dry runs still work).
PatchTools toolsFor(ResolvedToolchain tc, Map<String, String> env) {
  final snaps = tc.toolSnapshotPaths;
  final shipped = tc.bcVerifySnapshot;
  final override = env[bcVerifyEnv];
  final bc = File(shipped).existsSync()
      ? shipped
      : (override != null && override.isNotEmpty && File(override).existsSync() ? override : null);
  return PatchTools(
    flutterSdk: Directory(tc.flutterSdk).resolveSymbolicLinksSync(),
    dartAotRuntime: tc.dartAotRuntime,
    dart2bytecode: snaps['dart2bytecode']!,
    pkgRename: snaps['pkg_rename']!,
    patchGuard: snaps['patch_guard']!,
    bcVerify: bc,
  );
}
