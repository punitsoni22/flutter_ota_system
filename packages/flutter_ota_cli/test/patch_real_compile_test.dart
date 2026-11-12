// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// One REAL module build with the lab toolchain: pkg_rename -> patch_guard -> dart2bytecode
// (against a recorded Phase 3C baseline's link.dill and interface) -> bc_verify, then a local
// signature checked by patch_security's verifyPatch. The lab files are only read.
//
// Opt-in (it compiles real code; about a minute, about 1 GB of memory):
//   FLUTTER_OTA_LAB_TESTS=1 FLUTTER_OTA_BC_VERIFY=<bc_verify.aot> dart test test/patch_real_compile_test.dart
// Optional: FLUTTER_OTA_LAB (default ~/.cache/flutter-ota-lab), FLUTTER_OTA_LAB_BASELINE.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/build_support/canonical_paths.dart';
import 'package:flutter_ota_cli/src/features/discovery.dart';
import 'package:flutter_ota_cli/src/features/package_graph.dart';
import 'package:flutter_ota_cli/src/patch/module_builder.dart';
import 'package:flutter_ota_cli/src/patch/pipeline.dart';
import 'package:flutter_ota_cli/src/patch/process.dart';
import 'package:flutter_ota_cli/src/patch/release_record.dart';
import 'package:flutter_ota_cli/src/signing/key_store.dart';
import 'package:flutter_ota_cli/src/signing/patch_signer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'patch_support.dart';

final _env = Platform.environment;
final lab = _env['FLUTTER_OTA_LAB'] ?? p.join(_env['HOME'] ?? '', '.cache', 'flutter-ota-lab');
final baseline =
    _env['FLUTTER_OTA_LAB_BASELINE'] ?? p.join(lab, 'baselines', 'p3-98657508-43bd-4e97-a7f1-f9057b50cd23');
final flutterSdk = p.join(lab, 'flutter');
final pubCache = _env['PUB_CACHE'] ?? p.join(_env['HOME'] ?? '', '.pub-cache');

String? _skipReason() {
  if (_env['FLUTTER_OTA_LAB_TESTS'] != '1') return 'set FLUTTER_OTA_LAB_TESTS=1 to run the real lab compile';
  for (final f in [
    p.join(baseline, 'link.dill'),
    p.join(lab, 'work', 'tools', 'dart2bytecode.aot'),
    p.join(lab, 'work', 'tools', 'pkg_rename.aot'),
    p.join(lab, 'work', 'tools', 'patch_guard.aot'),
  ]) {
    if (!File(f).existsSync()) return 'lab file missing: $f';
  }
  return null;
}

/// Minimum language version from an SDK constraint (`^3.4.0`, `>=3.4.0 <4.0.0`).
String _lang(Object? sdk) {
  final m = RegExp(r'(\d+)\.(\d+)').firstMatch('$sdk');
  return m == null ? '3.0' : '${m.group(1)}.${m.group(2)}';
}

/// The package config `flutter pub get` would write for the baseline app (sources resolved from
/// the copied local packages, the pub cache and the lab Flutter SDK).
String _writeBaselinePackageConfig(String dir, String packagesDir) {
  final lock = loadYaml(File(p.join(baseline, 'pubspec.lock')).readAsStringSync()) as YamlMap;
  final entries = <Map<String, Object?>>[];
  (lock['packages'] as YamlMap).forEach((name, v) {
    final y = v as YamlMap;
    final String root;
    switch (y['source']) {
      case 'hosted':
        root = p.join(pubCache, 'hosted', 'pub.dev', '$name-${y['version']}');
      case 'path':
        root = p.join(packagesDir, '$name');
      default:
        root = name == 'sky_engine'
            ? p.join(flutterSdk, 'bin', 'cache', 'pkg', 'sky_engine')
            : p.join(flutterSdk, 'packages', '$name');
    }
    final pub = loadYaml(File(p.join(root, 'pubspec.yaml')).readAsStringSync()) as YamlMap;
    entries.add({
      'name': name,
      'rootUri': Uri.directory(root).toString(),
      'packageUri': 'lib/',
      'languageVersion': _lang((pub['environment'] as YamlMap?)?['sdk']),
    });
  });
  final path = p.join(dir, 'package_config.json');
  File(path).writeAsStringSync(jsonEncode({'configVersion': 2, 'packages': entries}));
  return path;
}

void main() {
  final skip = _skipReason();
  late Directory tmp;
  late String packagesDir;
  late String appConfig;
  late Map<String, LocalPackage> local;

  setUp(() {
    if (skip != null) return;
    tmp = Directory.systemTemp.createTempSync('flutter_ota_real_compile');
    packagesDir = p.join(tmp.path, 'packages');
    copyTree(p.join(baseline, 'src', 'packages'), packagesDir);
    appConfig = _writeBaselinePackageConfig(tmp.path, packagesDir);
    local = {
      for (final d in Directory(packagesDir).listSync().whereType<Directory>())
        p.basename(d.path): LocalPackage.read(d.path, tmp.path),
    };
  });
  tearDown(() {
    if (skip == null) tmp.deleteSync(recursive: true);
  });

  ModuleSpec spec() => ModuleSpec(
    moduleName: 'ota_patch_1',
    suffix: 'ota1',
    features: [
      FeatureEntry(
        package: 'feature_catalog',
        className: 'CatalogFeatureImpl',
        libraryUri: 'package:feature_catalog/feature_catalog.dart',
        declaredIn: 'lib/feature_catalog.dart',
        candidates: const [],
      ),
    ],
    packages: ['feature_catalog'],
    local: local,
    sharedPackages: local.keys.where((k) => k != 'feature_catalog').toList(),
    appPackageConfig: appConfig,
    hostLock: p.join(baseline, 'pubspec.lock'),
    hostPackagesJson: p.join(baseline, 'host_packages.json'),
    linkDill: p.join(baseline, 'link.dill'),
    dynamicInterface: p.join(baseline, 'dynamic_interface.yaml'),
    pubCache: pubCache,
    workDir: p.join(tmp.path, 'work'),
    mapping: PathMapping({'/': '/'}),
    canonicalFlutterSdk: flutterSdk,
    sdkConstraint: '^3.13.0',
  );

  final bcVerify = _env['FLUTTER_OTA_BC_VERIFY'];
  ModuleBuilder builder(List<String> log) => ModuleBuilder(
    tools: PatchTools(
      flutterSdk: flutterSdk,
      dartAotRuntime: p.join(flutterSdk, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime'),
      dart2bytecode: p.join(lab, 'work', 'tools', 'dart2bytecode.aot'),
      pkgRename: p.join(lab, 'work', 'tools', 'pkg_rename.aot'),
      patchGuard: p.join(lab, 'work', 'tools', 'patch_guard.aot'),
      bcVerify: bcVerify != null && File(bcVerify).existsSync() ? bcVerify : null,
    ),
    run: runLowPriority,
    log: log.add,
  );

  test(
    'real module: rename, guard, compile, reference verifier, sign, patch_security',
    () async {
      final log = <String>[];
      final built = await builder(log).build(spec(), requireVerifier: bcVerify != null);
      final module = File(built.modulePath).readAsBytesSync();
      expect(module.length, greaterThan(1000));
      expect(built.renames, {'feature_catalog': 'feature_catalog_ota1'});
      expect(built.guardReport!['accepted'], isTrue);
      if (bcVerify != null) expect(built.verifierOutput, startsWith('OK'));
      final entry = File(p.join(tmp.path, 'work', 'src', 'ota_patch_1', 'lib', 'entry.dart')).readAsStringSync();
      expect(entry, contains("import 'package:feature_catalog_ota1/feature_catalog.dart' as feature_feature_catalog;"));
      printOnFailure(log.join('\n'));

      // Sign it for the baseline's identity and verify it like the device does.
      final b = jsonDecode(File(p.join(baseline, 'baseline.json')).readAsStringSync()) as Map<String, Object?>;
      final env = {'HOME': tmp.path, 'FLUTTER_OTA_CONFIG_DIR': p.join(tmp.path, 'config')};
      final keys = createTestKeys(env);
      final relDir = writeTestRelease(tmp.path, rootKeys: keys.roots, hostPackages: {'flutter'});
      final release = ReleaseRecord.load(relDir);
      final signer = loadLocalSigner(
        env,
        appId: testAppId,
        environment: 'production',
        now: DateTime.now(),
        rootPublicKeys: keys.roots,
      );
      final m = buildManifest(
        release: release,
        module: module,
        built: built,
        sequence: 1,
        patchId: randomUuidV4(),
        keyId: signer.keyId,
        now: DateTime.now(),
      );
      expect(
        (m['toolchain']! as Map)['id'],
        (b['toolchain']! as Map)['id'],
        reason: 'same toolchain record as the lab baseline',
      );
      final otp = File(p.join(tmp.path, 'patch.otp'))..writeAsBytesSync(signPatch(m, module, signer));
      final hostPackages =
          ((jsonDecode(File(p.join(baseline, 'host_packages.json')).readAsStringSync()) as Map)['all'] as List)
              .cast<String>();
      final res = await verifyWithPatchSecurity(
        {
          'app_id': release.appId,
          'release_id': release.releaseId,
          'baseline_libapp_sha256': release.libappSha256,
          'runtime': release.runtime,
          'interface_sha256': release.interfaceSha256,
          'host_packages': hostPackages,
          'host_owned_packages': ['app_core', 'app_models', 'shared_state'],
          'entry_contract': 3,
          'toolchain_id': release.toolchainId,
          'roots': keys.roots,
          'environment': 'production',
          'now': DateTime.now().toUtc().toIso8601String(),
        },
        [otp.path],
      );
      expect(res!.single, startsWith('OK ${m['patch_id']}'));
      expect(sha256.convert(module).toString(), (m['module']! as Map)['sha256']);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'real guard: a dynamic call in the feature is rejected (exit 4) before compiling',
    () async {
      final f = File(p.join(packagesDir, 'feature_catalog', 'lib', 'feature_catalog.dart'));
      f.writeAsStringSync('${f.readAsStringSync()}\nObject? otaDynamicProbe(dynamic x) => x.anything();\n');
      final log = <String>[];
      await expectLater(
        builder(log).build(spec(), requireVerifier: false),
        throwsA(
          isA<CliException>()
              .having((e) => e.exitCode, 'exitCode', 4)
              .having((e) => e.message, 'm', contains('Dynamic invocation')),
        ),
      );
      expect(File(p.join(tmp.path, 'work', 'module.bc')).existsSync(), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
