// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../build_support/canonical_paths.dart';
import '../build_support/dynamic_interface.dart';
import '../build_support/kernel_libraries.dart';
import '../build_support/ota_config.dart';
import '../build_support/toolchain_build.dart';
import '../build_support/zip_reader.dart';
import '../context.dart';
import '../errors.dart';
import '../keys/key_store.dart';
import '../project/lockfile.dart';
import '../server/admin_client.dart';
import '../server/app_state.dart';
import '../toolchain/manager.dart';
import '../version.dart';
import '../features/generator.dart' show generateFeatureRegistry;
import '../features/snapshot.dart' show recordFeatureSnapshot;
import 'app_project.dart';
import 'ota_entry.dart';

/// Format of `release.json`.
const releaseRecordFormat = 1;

/// Files of a local release baseline (`.flutter_ota/releases/<release_id>/`). `patch android`
/// (4E) reads them.
const releaseJsonName = 'release.json';
const linkDillName = 'link.dill';
const dynamicInterfaceName = 'dynamic_interface.yaml';
const hostPackagesName = 'host_packages.json';
const linkPackageConfigName = 'link_package_config.json';
const baselineLibappName = 'libapp.so';
const pubspecLockCopyName = 'pubspec.lock';

/// Options of `flutter_ota release android`.
class AndroidReleaseOptions {
  AndroidReleaseOptions({
    this.kind = 'aab',
    this.buildName,
    this.buildNumber,
    this.extraArgs = const [],
    this.environment = defaultEnvironment,
    this.serverUrl,
    this.channel,
  });

  /// `aab` or `apk`.
  final String kind;
  final String? buildName;
  final String? buildNumber;

  /// Extra `flutter build` arguments (after `--`).
  final List<String> extraArgs;
  final String environment;
  final String? serverUrl;

  /// Optional update channel compiled into the app (the SDK's default is `production`).
  final String? channel;
}

/// What a successful release produced.
class AndroidReleaseResult {
  AndroidReleaseResult(this.releaseId, this.releaseDir, this.artifactPath, this.record);
  final String releaseId;
  final String releaseDir;
  final String artifactPath;
  final Map<String, Object?> record;
}

/// Flags of `flutter build` that the CLI sets itself or does not support yet.
const _refusedFlags = {
  '--target-platform': 'the CLI builds for android-arm64 only',
  '--extra-front-end-options': 'the CLI sets the dynamic interface itself',
  '--debug': 'releases are always --release builds',
  '--profile': 'releases are always --release builds',
  '--obfuscate': 'obfuscated store builds are not supported by the patch pipeline yet',
  '--dart-define-from-file': 'not supported yet; pass --dart-define=KEY=VALUE instead',
  '--target': 'the CLI builds lib/main.dart',
  '-t': 'the CLI builds lib/main.dart',
  '--build-name': 'use `flutter_ota release android --build-name`',
  '--build-number': 'use `flutter_ota release android --build-number`',
};

/// Checks the extra `flutter build` arguments and returns the user's `--dart-define` values
/// (`KEY=VALUE`), which must also go into `link.dill`.
List<String> validateExtraArgs(List<String> args) {
  final defines = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    final flag = a.contains('=') ? a.substring(0, a.indexOf('=')) : a;
    final reason = _refusedFlags[flag];
    if (reason != null) throw CliException('`$a` is not allowed after `--`: $reason.');
    String? define;
    if (flag == '--dart-define') {
      if (a.contains('=')) {
        define = a.substring(a.indexOf('=') + 1);
      } else {
        if (i + 1 >= args.length) throw CliException('--dart-define needs a value.');
        define = args[++i];
      }
    }
    if (define != null) {
      final name = define.split('=').first;
      if (name == otaConfigDefine) {
        throw CliException('$otaConfigDefine is set by flutter_ota; do not pass it yourself.');
      }
      if (define.contains(',')) {
        throw CliException('--dart-define values must not contain commas ("$define").');
      }
      defines.add(define);
    }
  }
  return defines;
}

/// Runs the whole release: checks, toolchain, interface, link.dill, store build, verification,
/// local baseline and server registration.
class AndroidRelease {
  AndroidRelease(this.ctx, this.options);

  final CliContext ctx;
  final AndroidReleaseOptions options;

  /// The store file of the current build, once flutter build has written it.
  String? _artifactPath;

  void _say(String s) => ctx.out.writeln(s);

  Future<AndroidReleaseResult> run() async {
    if (!const {'aab', 'apk'}.contains(options.kind)) throw CliException('--kind must be aab or apk.');
    if (!Platform.isLinux) throw CliException('flutter_ota release supports Linux x64 hosts only.');
    validateEnvironment(options.environment);
    if (options.channel != null && !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(options.channel!)) {
      throw CliException('--channel must be lower-case letters, digits and "-".');
    }
    final userDefines = validateExtraArgs(options.extraArgs);

    // 1. Project.
    final (dir, appId) = requireProject(ctx.workingDirectory);
    final app = AppProject.inspect(dir);
    if (!app.isFlutterApp) {
      throw CliException('${app.dir} is not a Flutter app (no `flutter: sdk: flutter` dependency).');
    }
    if (!app.hasAndroid) throw CliException('${app.dir} has no Android project (android/app/build.gradle[.kts]).');
    if (!app.hasMain) throw CliException('${app.dir} has no lib/main.dart.');
    if (!app.dependsOnSdk) {
      throw CliException(
        'pubspec.yaml does not depend on $sdkPackageName. Add it:\n'
        '  dependencies:\n    $sdkPackageName: ^0.1.0-alpha.1\n'
        'and call `await FlutterOta.initialize();` in main().',
      );
    }
    if (!app.mainCallsInitialize) {
      ctx.log('warning: lib/main.dart does not seem to call FlutterOta.initialize(); patches will not load.');
    }
    final version = _version(app);
    final lock = Lockfile.readIn(dir);
    if (lock == null) {
      throw CliException(
        'This project has no $lockFileName yet. Pin the OTA toolchain once with:\n'
        '  flutter_ota toolchain install\n'
        'and commit $lockFileName.',
      );
    }

    // 2. Server checks before the long build.
    final client = AdminClient.fromContext(ctx, serverUrlFlag: options.serverUrl);
    try {
      final health = await client.health();
      if (health != null) throw CliException('The server ${client.baseUrl} is not reachable ($health).');
      final server = await fetchAppState(client, appId);
      final keys = AppKeyStore.forApp(ctx.environment, appId);
      final roots = selectRootKeys(keys.rootPublicKeys(), server);
      roots.warnings.forEach(ctx.log);
      if (keys.activeSigner(options.environment, DateTime.now()) == null) {
        ctx.log(
          'warning: no valid signer certificate for "${options.environment}" on this machine; '
          '`flutter_ota keys init` creates one (needed later by `flutter_ota patch android`).',
        );
      }
      for (final r in await client.listReleases(server.slug)) {
        if (r['platform'] == 'android' && r['version'] == version) {
          throw CliException(
            'The server already has an Android release $version (id ${r['id']}).\n'
            'Every store build needs a new build number: pass --build-number or bump `version:` in pubspec.yaml.',
          );
        }
      }

      // 3. Toolchain (never a stock or global Flutter).
      final manager = ToolchainManager(ctx);
      final tc = await _resolveToolchain(manager, lock, dir);
      final tcRecord = jsonDecode(File(tc.toolchainJson).readAsStringSync()) as Map<String, Object?>;
      final expectedEngineSha = expectedLibflutterSha256(tc, lock.engine);

      // 4. Build.
      final releaseId = newUuidV4();
      _say('Release $releaseId: building $version (${options.kind}, android-arm64) with ${lock.toolchain}');
      // The baseline is written straight into its final folder (so recorded paths never change)
      // and removed again if anything fails before the server has the release.
      final releaseDir = Directory(p.join(app.releasesDir, releaseId))..createSync(recursive: true);
      var keep = false;
      var created = false;
      final canon = CanonicalBuildRoot.acquire(ctx.environment, log: ctx.log);
      try {
        final built = await _build(
          app: app,
          appId: appId,
          lock: lock,
          tc: tc,
          tcRecord: tcRecord,
          canon: canon,
          tmp: releaseDir.path,
          releaseId: releaseId,
          serverUrl: client.baseUrl,
          rootKeys: roots.embedded,
          userDefines: userDefines,
          version: version,
          expectedEngineSha: expectedEngineSha,
        );
        final record = built.record;
        _writeRecord(releaseDir.path, record);

        // 5. Register with the server (no APK/AAB, no source: only libapp.so for arm64).
        _say('Registering release $releaseId with ${client.baseUrl} ...');
        await client.createRelease(server.slug, _releaseBody(record));
        created = true;
        final libapp = File(p.join(releaseDir.path, baselineLibappName)).readAsBytesSync();
        final out = await client.uploadReleaseArtifact(releaseId, arm64Arch, libapp);
        final arts = ((out['artifacts'] as List?) ?? const []).cast<Map<String, Object?>>();
        final stored = arts.where((a) => a['arch'] == arm64Arch).firstOrNull;
        if (stored == null || stored['sha256'] != record['libapp_sha256']) {
          throw CliException('The server stored a different libapp.so hash than the local build.');
        }
        record['registered'] = {'server_url': client.baseUrl, 'app_slug': server.slug, 'arch': arm64Arch};
        _writeRecord(releaseDir.path, record);
        // The latest release, for tools that do not take a release id.
        _writeRecord(app.workDir, record);
        keep = true;
        return AndroidReleaseResult(releaseId, releaseDir.path, built.artifactPath, record);
      } finally {
        canon.release();
        if (!keep) {
          if (releaseDir.existsSync()) releaseDir.deleteSync(recursive: true);
          final built = _artifactPath;
          if (built != null) {
            ctx.log(
              'The release was not completed. Do NOT upload ${p.relative(built, from: dir)} to a store: '
              'its release id is not registered.${created ? ' The server has an incomplete release $releaseId '
                        '(version $version); delete it with `ota release delete` before retrying.' : ''}',
            );
          }
        }
      }
    } finally {
      client.close();
    }
  }

  String _version(AppProject app) {
    final (pubName, pubNumber) = app.version == null ? (null, null) : splitVersion(app.version!);
    final name = options.buildName ?? pubName;
    final number = options.buildNumber ?? pubNumber;
    if (name == null || name.isEmpty) {
      throw CliException('No version: add `version: 1.0.0+1` to pubspec.yaml or pass --build-name.');
    }
    if (number != null && !RegExp(r'^\d+$').hasMatch(number)) throw CliException('--build-number must be a number.');
    final v = number == null ? name : '$name+$number';
    if (v.length > 64 || v.contains(RegExp(r'\s'))) throw CliException('Invalid version "$v".');
    return v;
  }

  Future<ResolvedToolchain> _resolveToolchain(ToolchainManager m, Lockfile lock, String dir) async {
    final lockPath = p.join(dir, lockFileName);
    if (m.toolchainDirOverride == null && !m.installed().containsKey(lock.toolchain)) {
      _say('The toolchain ${lock.toolchain} is not installed yet; installing it (one time)...');
      final index = await m.loadIndex();
      final entry = index.byId(lock.toolchain);
      if (entry == null) {
        throw CliException('Toolchain ${lock.toolchain} is not in the verified index (${index.source}).');
      }
      if (!lock.matches(entry)) {
        throw CliException('The index entry for ${lock.toolchain} does not match $lockFileName. Refusing it.');
      }
      await m.install(entry);
    }
    return m.resolve(lock, lockPath: lockPath);
  }

  Future<_Built> _build({
    required AppProject app,
    required String appId,
    required Lockfile lock,
    required ResolvedToolchain tc,
    required Map<String, Object?> tcRecord,
    required CanonicalBuildRoot canon,
    required String tmp,
    required String releaseId,
    required String serverUrl,
    required Map<String, String> rootKeys,
    required List<String> userDefines,
    required String version,
    required String expectedEngineSha,
  }) async {
    final env = toolchainProcessEnvironment(ctx.environment, tc);
    final commands = <CommandRecord>[];
    final dir = app.dir;

    // The patch module loader: the toolchain's `dynamic_modules` package and the generated entry
    // point lib/flutter_ota_main.g.dart (docs/architecture/phase-4-sdk-runtime.md §3). The
    // developer's lib/main.dart is never changed.
    final loaderSha = installLoaderPackage(dir, locateLoaderPackage(tc, ctx.environment));
    if (ensureLoaderDependency(dir)) {
      ctx.log('Added `$loaderPackageName: {path: $loaderPackageRelDir}` to pubspec.yaml (commit it).');
    }

    _say('[1/6] flutter pub get (toolchain SDK)');
    await runChecked(
      tc.flutterBin,
      ['pub', 'get'],
      workingDirectory: dir,
      environment: env,
      sink: ctx.err,
      what: 'flutter pub get',
      record: commands,
    );

    // Feature registry (4F) for this package graph, then the entry point (written last, so it is
    // always exactly the binding text).
    final features = generateFeatureRegistry(dir);
    features.graph.warnings.where((w) => !w.contains(loaderPackageName)).forEach((w) => ctx.log('warning: $w'));
    writeOtaMain(dir);

    // Canonical paths: toolchain, pub cache and the app workspace are reached through symlinks
    // below the canonical root, so link.dill records no user-specific path.
    final packages = readPackageConfig(p.join(dir, '.dart_tool', 'package_config.json'));
    final tcReal = Directory(tc.root).resolveSymbolicLinksSync();
    final pubCacheDir = _pubCache();
    final pubCacheReal = Directory(pubCacheDir).existsSync() ? Directory(pubCacheDir).resolveSymbolicLinksSync() : null;
    final projectReal = Directory(dir).resolveSymbolicLinksSync();
    final local = [
      for (final pkg in packages)
        if (!p.isWithin(tcReal, pkg.root) && (pubCacheReal == null || !p.isWithin(pubCacheReal, pkg.root))) pkg,
    ];
    final workspace = commonAncestor([projectReal, ...local.map((x) => x.root)]);
    if (workspace == p.separator || workspace == ctx.environment['HOME']) {
      throw CliException(
        'The app and its path packages share no folder below your home directory ($workspace).\n'
        'Keep path packages inside one project folder.',
      );
    }
    canon.link(canonToolchain, tcReal);
    if (pubCacheReal != null) canon.link(canonPubCache, pubCacheReal);
    canon.link(canonWorkspace, workspace);
    final mapping = PathMapping({tcReal: canon.toolchain, ?pubCacheReal: canon.pubCache, workspace: canon.workspace});
    final linkConfig = p.join(tmp, linkPackageConfigName);
    File(linkConfig).writeAsStringSync(canonicalPackageConfig(packages, mapping));
    final canonProject = mapping.map(projectReal)!;
    final canonTmp = mapping.map(Directory(tmp).resolveSymbolicLinksSync())!;
    final canonTc = ResolvedToolchain(tc.id, tc.toolchainId, canon.toolchain);
    final entryUri = 'package:${app.packageName}/$otaMainFileName';

    _say('[2/6] Computing the dynamic interface from the app kernel');
    final pass1 = p.join(tmp, '.interface-pass.dill');
    await compileLinkKernel(
      flutterSdk: canonTc.flutterSdk,
      dartAotRuntime: tc.dartAotRuntime,
      packageConfig: p.join(canonTmp, linkPackageConfigName),
      entryUri: entryUri,
      outputDill: pass1,
      defines: userDefines,
      workingDirectory: canonProject,
      environment: env,
      sink: ctx.err,
      record: commands,
    );
    final libs1 = _kernelLibs(pass1);
    File(pass1).deleteSync();
    // Host packages: the packages the store build really contains (dev dependencies such as
    // flutter_test are in the package config but not in the app). sky_engine provides dart:ui.
    final inKernel = {
      for (final l in libs1)
        if (l.startsWith('package:') && l.contains('/')) l.substring('package:'.length, l.indexOf('/')),
    };
    final hostAll = [
      for (final x in packages)
        if (inKernel.contains(x.name) || x.name == 'sky_engine') x.name,
    ]..sort();
    final internal = [
      for (final x in local)
        if (hostAll.contains(x.name) && x.name != loaderPackageName) x.name,
    ]..sort();
    final iface = buildDynamicInterface(libs1, exclude: {entryUri});
    File(p.join(tmp, dynamicInterfaceName)).writeAsStringSync(iface.yaml);
    final ifaceCanon = p.join(canonTmp, dynamicInterfaceName);

    final runtime = {
      'abi': 'android-arm64',
      'dart': lock.dart,
      'engine': lock.engine.substring(0, 8),
      'flutter': lock.flutter,
      'runtime_id': 'dbc-${lock.toolchain}',
    };
    final config = buildOtaConfig(
      appId: appId,
      serverUrl: serverUrl,
      releaseId: releaseId,
      environment: options.environment,
      rootKeys: rootKeys,
      toolchainId: tc.toolchainId,
      runtime: runtime,
      interfaceSha256: iface.sha256Hex,
      hostPackages: hostAll,
      releaseVersion: version,
      channel: options.channel,
    );
    final configValue = encodeOtaConfig(config);
    final defines = ['$otaConfigDefine=$configValue', ...userDefines];

    _say('[3/6] Compiling link.dill (kernel that patches are compiled against)');
    final linkDill = p.join(tmp, linkDillName);
    await compileLinkKernel(
      flutterSdk: canonTc.flutterSdk,
      dartAotRuntime: tc.dartAotRuntime,
      packageConfig: p.join(canonTmp, linkPackageConfigName),
      entryUri: entryUri,
      outputDill: linkDill,
      defines: defines,
      dynamicInterface: ifaceCanon,
      workingDirectory: canonProject,
      environment: env,
      sink: ctx.err,
      record: commands,
    );
    final libs2 = _kernelLibs(linkDill);
    if (libs2.join('\n') != libs1.join('\n')) {
      throw CliException('The app kernel changed between two compiles (different libraries). Is a build running?');
    }

    _say('[4/6] flutter build ${options.kind == 'aab' ? 'appbundle' : 'apk'} --release (android-arm64)');
    final (buildName, buildNumber) = splitVersion(version);
    final buildArgs = [
      'build',
      options.kind == 'aab' ? 'appbundle' : 'apk',
      '--release',
      '-t',
      'lib/$otaMainFileName',
      '--target-platform',
      'android-arm64',
      '--dart-define=$otaConfigDefine=$configValue',
      '--extra-front-end-options=--dynamic-interface=$ifaceCanon',
      '--build-name=$buildName',
      if (buildNumber != null) '--build-number=$buildNumber',
      ...options.extraArgs,
    ];
    final started = DateTime.now().subtract(const Duration(seconds: 2));
    await runChecked(
      tc.flutterBin,
      buildArgs,
      workingDirectory: dir,
      environment: env,
      sink: ctx.err,
      what: 'flutter build',
      record: commands,
    );
    await _stopGradle(dir, env);

    _say('[5/6] Verifying the build');
    final artifact = _findOutput(dir, started);
    _artifactPath = artifact;
    final prefix = options.kind == 'aab' ? 'base/' : '';
    final zip = ZipReader.open(artifact);
    final List<int> libapp;
    final String engineSha;
    try {
      final engine = zip.read('$prefix$libflutterArm64');
      final app0 = zip.read('$prefix$libappArm64');
      if (engine == null || app0 == null) {
        throw CliException('${p.relative(artifact, from: dir)} has no arm64 libflutter.so/libapp.so.');
      }
      engineSha = sha256.convert(engine).toString();
      libapp = app0;
    } on FormatException catch (e) {
      throw CliException('Cannot read ${p.relative(artifact, from: dir)}: ${e.message}');
    } finally {
      zip.close();
    }
    if (engineSha != expectedEngineSha) {
      throw CliException(
        'The build does NOT contain the OTA engine (libflutter.so $engineSha, expected '
        '$expectedEngineSha from ${lock.toolchain}). A stock engine was picked up; nothing was registered.\n'
        'Run `flutter_ota toolchain doctor` and remove android/.gradle and build/ before retrying.',
      );
    }
    File(p.join(tmp, baselineLibappName)).writeAsBytesSync(libapp, flush: true);
    final libappSha = sha256.convert(libapp).toString();
    final artifactBytes = File(artifact).lengthSync();
    final artifactSha = await _sha256File(artifact);

    _say('[6/6] Writing the local baseline');
    // What the feature packages looked like at release time (4F; `patch android` diffs against it).
    recordFeatureSnapshot(dir, tmp);
    File(
      p.join(tmp, hostPackagesName),
    ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({'internal': internal, 'all': hostAll})}\n');
    final lockFile = File(p.join(dir, 'pubspec.lock'));
    if (lockFile.existsSync()) lockFile.copySync(p.join(tmp, pubspecLockCopyName));
    final record = <String, Object?>{
      'format': releaseRecordFormat,
      'app_id': appId,
      'release_id': releaseId,
      'platform': 'android',
      'version': version,
      'build_name': buildName,
      'build_number': buildNumber,
      'environment': options.environment,
      'server_url': serverUrl,
      'abi': 'android-arm64',
      'arch': arm64Arch,
      'libapp_sha256': libappSha,
      'libapp_size': libapp.length,
      'libflutter_sha256': engineSha,
      'artifact': {
        'kind': options.kind,
        'path': p.relative(artifact, from: dir),
        'sha256': artifactSha,
        'size': artifactBytes,
      },
      'engine': lock.engine,
      'flutter': lock.flutter,
      'dart': lock.dart,
      'dart_revision': tcRecord['dart_revision'],
      'bytecode_format': tcRecord['bytecode_format'],
      'toolchain': lock.toolchain,
      'toolchain_id': tc.toolchainId,
      // The content-hash fields of toolchain.json (without its "id", which is toolchain_id).
      'toolchain_record': {
        for (final e in tcRecord.entries)
          if (e.key != 'id') e.key: e.value,
      },
      'runtime': runtime,
      'interface_sha256': iface.sha256Hex,
      'interface_policy': interfacePolicyVersion,
      'interface_libraries': iface.libraries.length,
      'host_packages': hostAll,
      'root_keys': rootKeys,
      'entry_contract': entryContract,
      'flutter_ota_config': configValue,
      'link_dill_sha256': await _sha256File(linkDill),
      'canonical_build_root': canon.path,
      'link_entry': entryUri,
      'entry_target': 'lib/$otaMainFileName',
      'loader_package_sha256': loaderSha,
      'release_version': version,
      'channel': options.channel,
      'link_defines': defines,
      'build_args': buildArgs,
      'cli_version': cliVersion,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'registered': null,
    };
    return _Built(record, artifact, commands);
  }

  List<String> _kernelLibs(String dill) {
    try {
      return kernelLibraryUrisOfFile(dill);
    } on FormatException catch (e) {
      throw CliException('Cannot read the kernel file $dill: ${e.message}');
    }
  }

  String _pubCache() {
    final v = ctx.environment['PUB_CACHE'];
    if (v != null && v.isNotEmpty) return p.absolute(v);
    return p.join(ctx.home, '.pub-cache');
  }

  /// Stops the Gradle daemon this build started (it lives in the toolchain's own Gradle home).
  Future<void> _stopGradle(String dir, Map<String, String> env) async {
    final gradlew = p.join(dir, 'android', 'gradlew');
    if (!File(gradlew).existsSync()) return;
    try {
      await Process.run(
        gradlew,
        ['--stop'],
        workingDirectory: p.join(dir, 'android'),
        environment: env,
        includeParentEnvironment: false,
      ).timeout(const Duration(minutes: 2));
    } on Object {
      // best effort
    }
  }

  String _findOutput(String dir, DateTime started) {
    final base = options.kind == 'aab'
        ? p.join(dir, 'build', 'app', 'outputs', 'bundle')
        : p.join(dir, 'build', 'app', 'outputs', 'flutter-apk');
    final ext = options.kind == 'aab' ? '.aab' : '.apk';
    final d = Directory(base);
    final found = !d.existsSync()
        ? <File>[]
        : d
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith(ext) && f.path.contains('release') && f.lastModifiedSync().isAfter(started))
              .toList();
    if (found.isEmpty) throw CliException('flutter build finished, but no new release $ext was found in $base.');
    found.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return found.first.path;
  }

  Map<String, Object?> _releaseBody(Map<String, Object?> r) => {
    'platform': 'android',
    'version': r['version'],
    'flutter_version': r['flutter'],
    'engine_revision': r['engine'],
    'runtime_abi': (r['runtime'] as Map)['runtime_id'],
    'fingerprint': {
      'kind': 'flutter_ota_release',
      'format': releaseRecordFormat,
      'libapp_sha256': {arm64Arch: r['libapp_sha256']},
      'libflutter_sha256': r['libflutter_sha256'],
      'interface_sha256': r['interface_sha256'],
      'toolchain': r['toolchain'],
      'cli_version': cliVersion,
    },
    'id': r['release_id'],
    'toolchain_id': r['toolchain_id'],
    'dart_revision': r['dart_revision'],
    'bytecode_format': r['bytecode_format'],
    'interface_sha256': r['interface_sha256'],
    'trust_environment': r['environment'],
  };

  void _writeRecord(String dir, Map<String, Object?> record) {
    File(p.join(dir, releaseJsonName)).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(record)}\n');
  }
}

class _Built {
  _Built(this.record, this.artifactPath, this.commands);
  final Map<String, Object?> record;
  final String artifactPath;
  final List<CommandRecord> commands;
}

Future<String> _sha256File(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

/// A random (version 4) UUID.
String newUuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
