// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// `flutter_ota patch android`: from a project change to a signed, verified, uploaded patch.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../build_support/canonical_paths.dart';
import '../context.dart';
import '../errors.dart';
import '../features/codegen_check.dart';
import '../features/discovery.dart';
import '../features/package_graph.dart';
import '../features/snapshot.dart';
import '../project/project.dart';
import '../server/admin_client.dart';
import '../signing/certificate.dart';
import '../signing/key_store.dart';
import '../signing/patch_signer.dart';
import '../toolchain/canonical_json.dart';
import '../toolchain/es256.dart';
import 'container.dart';
import 'manifest.dart';
import 'module_builder.dart';
import 'planner.dart';
import 'process.dart';
import 'release_record.dart';
import 'upload.dart';

class PatchOptions {
  PatchOptions({this.releaseId, this.channel, this.rolloutPercent, this.dryRun = false, this.note = ''});
  final String? releaseId;
  final String? channel;
  final int? rolloutPercent;
  final bool dryRun;
  final String note;
}

class PatchResult {
  PatchResult({required this.plan, this.containerPath, this.manifest, this.serverPatchId, this.uploaded = false});
  final PatchPlan plan;
  final String? containerPath;
  final Map<String, Object?>? manifest;
  final String? serverPatchId;
  final bool uploaded;
}

/// Creates a random UUID version 4.
String randomUuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class PatchPipeline {
  PatchPipeline({
    required this.ctx,
    required this.projectDir,
    required this.tools,
    required this.toolchainRoot,
    required this.toolchainId,
    required this.processEnvironment,
    this.run = runLowPriority,
    DateTime Function()? clock,
    String Function()? newPatchId,
    PatchServer Function(String serverUrl, String adminKey)? serverFactory,
  }) : clock = clock ?? DateTime.now,
       newPatchId = newPatchId ?? randomUuidV4,
       serverFactory = serverFactory ?? ((url, key) => PatchServer(url, key, ctx.httpClientFactory()));

  final CliContext ctx;
  final String projectDir;
  final PatchTools tools;

  /// Real directory of the installed toolchain (`toolchains/<id>`).
  final String toolchainRoot;

  /// Toolchain id pinned by the project (`flutter_ota.lock`).
  final String toolchainId;

  /// Environment for child processes (toolchain first on PATH, isolated build settings).
  final Map<String, String> processEnvironment;
  final ToolRunner run;
  final DateTime Function() clock;
  final String Function() newPatchId;
  final PatchServer Function(String serverUrl, String adminKey) serverFactory;

  void _say(String s) => ctx.out.writeln(s);

  Future<PatchResult> execute(PatchOptions o) async {
    final appId = readAppId(projectDir);
    final release = ReleaseRecord.find(projectDir, releaseId: o.releaseId);
    if (release.appId != appId) {
      throw CliException(
        'Release ${release.releaseId} belongs to app ${release.appId}, but flutter_ota.yaml says $appId.',
      );
    }
    if (release.toolchainId != toolchainId) {
      throw CliException(
        'Release ${release.releaseId} was built with toolchain ${release.toolchainId}, but this project now pins '
        '$toolchainId. Patches only apply to apps built with the same toolchain (needs a new store release).',
        exitCode: 3,
      );
    }
    _say(
      'Patch for release ${release.releaseId}${release.version == null ? '' : ' (version ${release.version})'}, '
      'environment ${release.environment}',
    );

    _say('[1/7] Reading the project (flutter pub get with the toolchain SDK)');
    final pg = await run(
      tools.flutterBin,
      ['pub', 'get'],
      workingDirectory: projectDir,
      environment: processEnvironment,
    );
    if (pg.exitCode != 0) throw CliException('flutter pub get failed:\n${tail('${pg.stdout}\n${pg.stderr}')}');
    final project = ProjectPackages.load(projectDir);
    final graph = FeatureGraph.build(project);
    final diff = diffFeatureSnapshots(loadFeatureSnapshot(release.dir), captureFeatureSnapshot(projectDir));
    final plan = planPatch(graph, diff, release.hostPackages);

    _say('[2/7] Changes since the store release');
    for (final c in diff.changed) {
      _say('  ${c.name}: ${c.describe()}');
    }
    for (final n in plan.notes) {
      _say('  note: $n');
    }
    if (plan.refusals.isNotEmpty) {
      throw CliException(
        'This change cannot be shipped as a patch:\n${plan.refusals.map((r) => '  - $r').join('\n')}',
        exitCode: 3,
      );
    }
    if (plan.packages.isEmpty) {
      _say('No feature changed since release ${release.releaseId}. Nothing to patch.');
      return PatchResult(plan: plan);
    }
    _say(
      '  Patch contains (renamed copies): ${(plan.packages.toList()..sort()).map((x) => '$x (${plan.why[x]})').join('; ')}',
    );
    _say('  Feature slots filled: ${plan.features.join(', ')}');

    _say('[3/7] Checking generated code');
    final lock = p.join(projectDir, 'pubspec.lock');
    final versionProblems = [
      for (final n in plan.packages)
        ...codegenVersionProblems(project.local[n]!, File(lock).existsSync() ? lock : null),
    ];
    if (versionProblems.isNotEmpty) throw CliException(versionProblems.join('\n'), exitCode: 3);
    final scratch = Directory(p.join(projectDir, '.dart_tool', 'flutter_ota', 'scratch'))..createSync(recursive: true);
    final checker = CodegenChecker(
      project: project,
      dartBin: tools.dartBin,
      flutterSdk: tools.flutterSdk,
      run: run,
      workDir: scratch.path,
      environment: processEnvironment,
    );
    for (final n in (plan.changed.toList()..sort())) {
      final pkg = project.local[n]!;
      if (!pkg.usesBuildRunner) continue;
      final stale = await checker.staleFiles(pkg);
      if (stale.isNotEmpty) {
        throw CliException(
          'The generated code of $n is out of date (${stale.take(5).join(', ')}${stale.length > 5 ? ', ...' : ''}).\n'
          'A patch would ship the old generated code. Regenerate it:\n'
          '  cd ${pkg.relativeDir} && dart run build_runner build --delete-conflicting-outputs\n'
          'then run flutter_ota patch android again.',
          exitCode: 3,
        );
      }
      _say('  $n: generated files are up to date');
    }

    // Sequence: higher than every patch of this release on the server and locally.
    var sequence = release.localHighestSequence() + 1;
    PatchServer? server;
    if (!o.dryRun) {
      server = _server(release);
      sequence = max(sequence, await server.highestSequence(release.releaseId) + 1);
    }

    _say('[4/7] Building the module (rename, guard, compile, verify)');
    final canon = CanonicalBuildRoot.acquire(ctx.environment, log: ctx.log);
    final BuiltModule built;
    final String workDir;
    try {
      if (release.canonicalBuildRoot != null && release.canonicalBuildRoot != canon.path) {
        throw CliException(
          'Release ${release.releaseId} was built in the canonical build root ${release.canonicalBuildRoot}, '
          'this build uses ${canon.path}. Set $canonicalBuildRootEnv=${release.canonicalBuildRoot} for patches of this release.',
        );
      }
      final mapping = _linkCanonical(canon, project);
      workDir = p.join(canon.path, 'patch', 'ota_patch_$sequence');
      final fullMapping = PathMapping({..._mappingPairs, p.join(canon.path, 'patch'): p.join(canon.path, 'patch')});
      final spec = ModuleSpec(
        moduleName: 'ota_patch_$sequence',
        suffix: 'ota$sequence',
        features: [for (final f in plan.features) graph.features[f]!],
        packages: plan.packages.toList()..sort(),
        local: project.local,
        sharedPackages: [
          ...graph.packagesWithRole(PackageRole.shared),
          ...project.outsideProject,
          ...project.toolOwned,
        ],
        appPackageConfig: project.config.path,
        hostLock: File(release.pubspecLock).existsSync() ? release.pubspecLock : lock,
        hostPackagesJson: release.hostPackagesJson,
        linkDill: release.linkDill,
        dynamicInterface: release.dynamicInterface,
        pubCache: _pubCache(),
        workDir: workDir,
        mapping: fullMapping,
        canonicalFlutterSdk: mapping.map(Directory(tools.flutterSdk).resolveSymbolicLinksSync()) ?? tools.flutterSdk,
      );
      built = await ModuleBuilder(
        tools: tools,
        run: run,
        log: _say,
        environment: processEnvironment,
      ).build(spec, requireVerifier: !o.dryRun);
    } finally {
      canon.release();
    }
    final module = File(built.modulePath).readAsBytesSync();
    _say(
      '  module: ${module.length} bytes${built.verifierOutput == null ? ' (reference verifier NOT run)' : ', ${built.verifierOutput}'}',
    );

    _say('[5/7] Manifest and local signature');
    final now = clock().toUtc();
    final manifest = buildManifest(
      release: release,
      module: module,
      built: built,
      sequence: sequence,
      patchId: newPatchId(),
      keyId: '',
      now: now,
    );
    LocalSigner? signer;
    try {
      signer = loadLocalSigner(
        ctx.environment,
        appId: appId,
        environment: release.environment,
        now: now,
        rootPublicKeys: release.rootKeys,
      );
    } on CliException catch (e) {
      if (!o.dryRun) rethrow;
      _say('  warning: ${e.message.split('\n').first} (a real run stops here)');
    }
    final outDir = Directory(p.join(release.patchesDir, '$sequence'));
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    outDir.createSync(recursive: true);
    String? containerPath;
    Uint8List? container;
    if (signer != null) {
      manifest['key_id'] = signer.keyId;
      container = signPatch(manifest, module, signer);
      checkSignedContainer(container, signer.certificate, release.rootKeys);
      containerPath = p.join(outDir.path, 'patch.otp');
      File(containerPath).writeAsBytesSync(container, flush: true);
      _say(
        '  signed with ${signer.keyId} (certificate serial ${signer.certificate.serial}); ${container.length} bytes',
      );
    }
    final summary = {
      'release_id': release.releaseId,
      'sequence': sequence,
      'manifest': manifest,
      'packages': plan.packages.toList()..sort(),
      'features': plan.features,
      'reasons': plan.why,
      'renames': built.renames,
      'guard': built.guardReport == null
          ? null
          : {'accepted': built.guardReport!['accepted'], 'findings': built.guardReport!['findings']},
      'reference_verifier': built.verifierOutput,
      'signed': container != null,
      'dry_run': o.dryRun,
      'server_patch_id': null,
    };
    File(p.join(outDir.path, 'patch.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));

    _say('[6/7] Summary');
    _say('  manifest patch_id ${manifest['patch_id']}, sequence $sequence, features ${plan.features.join(', ')}');
    _say('  files: ${outDir.path}');
    if (o.dryRun) {
      _say('[7/7] Dry run: nothing was uploaded.');
      return PatchResult(plan: plan, containerPath: containerPath, manifest: manifest);
    }

    _say('[7/7] Uploading');
    if (container == null || built.verifierOutput == null) {
      throw CliException('Refusing to upload: the patch is not signed or not verified.');
    }
    final s = server!;
    try {
      final created = await s.createPatch(release.releaseId, note: o.note);
      final id = created['id'] as String;
      await s.uploadArtifact(id, (release.json['arch'] as String?) ?? arm64Arch, container);
      summary['server_patch_id'] = id;
      File(p.join(outDir.path, 'patch.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
      _say('  uploaded as server patch $id (number ${created['number']}), status draft');
      if (o.channel != null) {
        final pct = o.rolloutPercent ?? 100;
        await s.publish(id, o.channel!, pct);
        _say('  published to channel ${o.channel} for $pct% of devices');
        if (o.channel != 'production') {
          _say('  after testing, promote it (server patch id):  ota patch promote $id --percent <n>');
        }
      } else {
        _say('  not published. Publish it with:  ota patch publish $id --channel <channel> --percent <n>');
      }
      return PatchResult(
        plan: plan,
        containerPath: containerPath,
        manifest: manifest,
        serverPatchId: id,
        uploaded: true,
      );
    } finally {
      s.close();
    }
  }

  final _mappingPairs = <String, String>{};

  /// Links toolchain, pub cache and workspace below the canonical root exactly as the release
  /// command does, so patch sources and the release kernel share the same paths. (The release
  /// links `<root>/workspace` to its build copy of this workspace, which has the same layout, so
  /// the canonical paths in link.dill and in the patch module are identical.)
  PathMapping _linkCanonical(CanonicalBuildRoot canon, ProjectPackages project) {
    final packages = readPackageConfig(project.config.path);
    final tcReal = Directory(toolchainRoot).resolveSymbolicLinksSync();
    final pc = _pubCache();
    final pubReal = Directory(pc).existsSync() ? Directory(pc).resolveSymbolicLinksSync() : null;
    final projectReal = Directory(projectDir).resolveSymbolicLinksSync();
    // Same workspace as `release android`, whose link.dill reaches the build copy of this folder
    // through the same <root>/workspace link (identical relative layout).
    final workspace = appWorkspace(
      projectReal: projectReal,
      packages: packages,
      toolchainReal: tcReal,
      pubCacheReal: pubReal,
      home: ctx.environment['HOME'],
    );
    canon.link(canonToolchain, tcReal);
    if (pubReal != null) canon.link(canonPubCache, pubReal);
    canon.link(canonWorkspace, workspace);
    _mappingPairs
      ..clear()
      ..[tcReal] = canon.toolchain
      ..[workspace] = canon.workspace;
    if (pubReal != null) _mappingPairs[pubReal] = canon.pubCache;
    return PathMapping(_mappingPairs);
  }

  String _pubCache() {
    final v = ctx.environment['PUB_CACHE'];
    if (v != null && v.isNotEmpty) return p.absolute(v);
    return p.join(ctx.environment['HOME'] ?? '.', '.pub-cache');
  }

  PatchServer _server(ReleaseRecord release) {
    if (release.registered == null) {
      throw CliException(
        'Release ${release.releaseId} is not registered on a server, so patches for it cannot be uploaded. '
        'Use --dry-run to build the patch locally.',
      );
    }
    final url = resolveServerUrl(ctx) ?? release.serverUrl;
    if (url == null) throw CliException(missingServerUrlMessage);
    final key = ctx.environment[adminKeyEnv];
    if (key == null || key.trim().isEmpty) throw CliException(missingAdminKeyMessage);
    return serverFactory(url, key.trim());
  }
}

/// Builds the manifest v2 of a patch (patch_security schema, entry contract 3).
Map<String, Object?> buildManifest({
  required ReleaseRecord release,
  required Uint8List module,
  required BuiltModule built,
  required int sequence,
  required String patchId,
  required String keyId,
  required DateTime now,
}) => {
  'format': 2,
  'app_id': release.appId,
  'release_id': release.releaseId,
  'baseline_libapp_sha256': release.libappSha256,
  'patch_id': patchId,
  'sequence': sequence,
  'key_id': keyId,
  'created_at': isoUtcSeconds(now),
  'runtime': {
    for (final k in ['abi', 'dart', 'engine', 'flutter', 'runtime_id']) k: release.runtime[k],
  },
  'module': {
    'format': 'dart-bytecode',
    'sha256': sha256.convert(module).toString(),
    'size': module.length,
    'entry_contract': entryContract,
  },
  'packages': [
    for (final e in (built.renames.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
      {'name': e.key, 'module_name': e.value, 'version': built.packageVersions[e.key] ?? '0.0.0', 'source': 'internal'},
  ],
  'host_interface': {'sha256': release.interfaceSha256, 'host_packages': built.hostPackages},
  'assets': <Object?>[],
  'toolchain': release.manifestToolchain,
};

/// Re-reads a signed container and checks it like the server does before upload: bounds,
/// canonical manifest, schema, certified signature (and the certificate's root signature with
/// [rootKeys]), module size and hash. Throws [CliException].
void checkSignedContainer(Uint8List container, KeyCertificate cert, Map<String, String> rootKeys) {
  final ContainerParts parts;
  try {
    parts = splitContainer(container);
  } on FormatException catch (e) {
    throw CliException('The signed container is malformed (${e.message}).');
  }
  final m = jsonDecode(utf8.decode(parts.manifest)) as Map<String, Object?>;
  if (canonicalJsonString(m) != utf8.decode(parts.manifest)) throw CliException('The manifest is not canonical JSON.');
  validatePatchManifest(m);
  final sig = jsonDecode(utf8.decode(parts.signature)) as Map<String, Object?>;
  final ok = es256Verify(
    parseEs256PublicKey(cert.publicKey),
    domainMessage(manifestDomain, parts.manifest),
    sig['sig'] as String,
  );
  if (!ok || sig['key_id'] != m['key_id']) throw CliException('The patch signature does not verify.');
  if (rootKeys.isNotEmpty && !cert.verifiesWith(rootKeys)) {
    throw CliException('The signer certificate is not signed by a root key of this release.');
  }
  final mod = m['module']! as Map;
  if (parts.module.length != mod['size'] || sha256.convert(parts.module).toString() != mod['sha256']) {
    throw CliException('The module bytes do not match the manifest.');
  }
}
