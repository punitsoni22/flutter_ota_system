// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Builds the bytecode module of a patch. Port of
// prototypes/real_app_compatibility/scripts/make_module.sh to Dart, with no Python step:
//
//   1. module package: pubspec + generated entry (contract 3: slot name -> factory);
//   2. pkg_rename prepare: copy the patched packages, rename them (`<name>_ota<seq>`), rewrite
//      package URIs in directives only (analyzer parser), check the closure rule and the policy;
//   3. package config: the store build's resolution (the app's package config) plus the
//      renamed copies, with every path below the canonical build root (no home directory paths
//      in the bytecode);
//   4. patch_guard --host-packages: every module package is analysed (compile errors, FFI,
//      mirrors, dart:_ libraries, dynamic calls, noSuchMethod, undeclared dependencies);
//   5. dart2bytecode against the release's link.dill, validated against its dynamic interface;
//   6. reference bytecode verifier (bc_verify).
//
// Every tool runs from the pinned toolchain's AOT snapshots through `dartaotruntime`.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../build_support/canonical_paths.dart';
import '../errors.dart';
import '../features/discovery.dart';
import '../features/package_graph.dart';
import 'process.dart';

/// Exit code of pkg_rename when it refuses a module.
const pkgRenameRefused = 3;

/// Exit code of patch_guard when it rejects a module.
const patchGuardRejected = 4;

/// Paths of the toolchain programs a patch build uses.
class PatchTools {
  PatchTools({
    required this.flutterSdk,
    required this.dartAotRuntime,
    required this.dart2bytecode,
    required this.pkgRename,
    required this.patchGuard,
    this.bcVerify,
  });

  /// Real path of the toolchain's Flutter SDK.
  final String flutterSdk;
  final String dartAotRuntime;
  final String dart2bytecode;
  final String pkgRename;
  final String patchGuard;

  /// Reference bytecode verifier snapshot; null when not available.
  final String? bcVerify;

  String get flutterBin => p.join(flutterSdk, 'bin', 'flutter');
  String get dartBin => p.join(flutterSdk, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
}

/// Input of one module build.
class ModuleSpec {
  ModuleSpec({
    required this.moduleName,
    required this.suffix,
    required this.features,
    required this.packages,
    required this.local,
    required this.sharedPackages,
    required this.appPackageConfig,
    required this.hostLock,
    required this.hostPackagesJson,
    required this.linkDill,
    required this.dynamicInterface,
    required this.pubCache,
    required this.workDir,
    required this.mapping,
    required this.canonicalFlutterSdk,
    this.sdkConstraint = '^3.8.0',
  });

  /// Name of the module package (`ota_patch_<seq>`).
  final String moduleName;

  /// Rename suffix: package `x` becomes `x_<suffix>`.
  final String suffix;

  /// Feature entries whose slots the module fills.
  final List<FeatureEntry> features;

  /// Local packages copied and renamed into the module.
  final List<String> packages;

  /// All local packages of the project (name -> package).
  final Map<String, LocalPackage> local;

  /// Shared (host-owned) local packages: pkg_rename refuses to copy them.
  final List<String> sharedPackages;

  /// The app's `.dart_tool/package_config.json` (the store build's resolution).
  final String appPackageConfig;
  final String hostLock;
  final String hostPackagesJson;
  final String linkDill;
  final String dynamicInterface;
  final String pubCache;

  /// Work directory below the canonical build root.
  final String workDir;

  /// Real path prefix -> canonical path prefix (toolchain, pub cache, workspace, work dir).
  final PathMapping mapping;

  /// The toolchain's Flutter SDK seen through the canonical root.
  final String canonicalFlutterSdk;
  final String sdkConstraint;

  String renamed(String pkg) => '${pkg}_$suffix';
}

/// Output of a module build.
class BuiltModule {
  BuiltModule({
    required this.modulePath,
    required this.renames,
    required this.hostPackages,
    required this.guardReport,
    required this.verifierOutput,
    required this.packageVersions,
  });
  final String modulePath;

  /// original -> renamed
  final Map<String, String> renames;

  /// Packages the module resolves from the store build (manifest host_interface.host_packages).
  final List<String> hostPackages;
  final Map<String, Object?>? guardReport;

  /// Output of the reference verifier, null when it did not run.
  final String? verifierOutput;

  /// original -> version (from its pubspec)
  final Map<String, String> packageVersions;
}

/// Source of the generated module entry (contract 3). Imports use the ORIGINAL package names;
/// pkg_rename rewrites them to the renamed copies.
String renderModuleEntry(List<FeatureEntry> features) {
  final fs = [...features]..sort((a, b) => a.slot.compareTo(b.slot));
  final b = StringBuffer()
    ..writeln('// Generated by `flutter_ota patch android`. Do not edit.')
    ..writeln('// Module entry contract 3: slot name -> factory of the patched feature.')
    ..writeln()
    ..writeln("import 'dart:typed_data';")
    ..writeln();
  for (final f in fs) {
    b.writeln("import '${f.libraryUri}' as feature_${f.package};");
  }
  b
    ..writeln()
    ..writeln("@pragma('dyn-module:entry-point')")
    ..writeln('Object? otaPatchEntry() => <String, Object?>{')
    ..writeln("  'contract': 3,")
    ..writeln("  'features': <String, Object? Function()>{");
  for (final f in fs) {
    b.writeln("    '${f.slot}': () => feature_${f.package}.${f.className}(),");
  }
  b
    ..writeln('  },')
    ..writeln("  'assets': <String, Uint8List>{},")
    ..writeln('};');
  return b.toString();
}

class ModuleBuilder {
  ModuleBuilder({required this.tools, required this.run, required this.log, this.environment = const {}});

  final PatchTools tools;
  final ToolRunner run;
  final void Function(String) log;
  final Map<String, String> environment;

  Future<ToolResult> _tool(String snapshot, List<String> args, {String? cwd}) =>
      run(tools.dartAotRuntime, [snapshot, ...args], workingDirectory: cwd, environment: environment);

  /// Builds the module. Throws [CliException] (exit code 3 = refused, 4 = rejected by the
  /// guard, 1 = build error).
  Future<BuiltModule> build(ModuleSpec spec, {bool requireVerifier = true}) async {
    final work = Directory(spec.workDir);
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
    final specDir = p.join(spec.workDir, 'spec');
    final srcDir = p.join(spec.workDir, 'src');
    final pkgRoot = p.join(spec.workDir, 'packages');

    // 1. Module package (written against the original names).
    Directory(p.join(specDir, 'lib')).createSync(recursive: true);
    final pubspec = StringBuffer()
      ..writeln('name: ${spec.moduleName}')
      ..writeln('publish_to: none')
      ..writeln('version: 1.0.0')
      ..writeln('environment:')
      ..writeln('  sdk: ${jsonEncode(spec.sdkConstraint)}')
      ..writeln('dependencies:');
    for (final f in spec.features) {
      pubspec.writeln('  ${f.package}:\n    path: ${jsonEncode(p.join(pkgRoot, f.package))}');
    }
    File(p.join(specDir, 'pubspec.yaml')).writeAsStringSync(pubspec.toString());
    File(p.join(specDir, 'lib', 'entry.dart')).writeAsStringSync(renderModuleEntry(spec.features));
    File(p.join(specDir, 'module.yaml')).writeAsStringSync(
      '# Generated by flutter_ota patch android.\n'
      'kind: patch\n'
      'suffix: ${spec.suffix}\n'
      'change:\n${(spec.packages.toList()..sort()).map((x) => '  - $x\n').join()}',
    );
    final policy = p.join(spec.workDir, 'policy.yaml');
    File(policy).writeAsStringSync(
      '# Generated by flutter_ota patch android.\n'
      'host_owned:\n${spec.sharedPackages.isEmpty ? '  []\n' : (spec.sharedPackages.toList()..sort()).map((x) => '  - $x\n').join()}'
      'sdk_packages:\n  - flutter\n  - sky_engine\n'
      'host_runtime:\n  - $sdkPackageName\n',
    );
    // pkg_rename reads every local package from one directory: link them there by name.
    Directory(pkgRoot).createSync();
    for (final l in spec.local.values) {
      Link(p.join(pkgRoot, l.name)).createSync(l.dir);
    }

    // 2. Rename.
    log('  pkg_rename: copying and renaming ${spec.packages.join(', ')}');
    final rn = await _tool(tools.pkgRename, [
      'prepare',
      '--module',
      specDir,
      '--packages-root',
      pkgRoot,
      '--host-lock',
      spec.hostLock,
      '--pub-cache',
      spec.pubCache,
      '--policy',
      policy,
      '--out',
      srcDir,
    ]);
    if (rn.exitCode == pkgRenameRefused) {
      throw CliException('pkg_rename refused the patch:\n${tail(rn.stderr)}', exitCode: 3);
    }
    if (rn.exitCode != 0) {
      throw CliException('pkg_rename failed (exit ${rn.exitCode}):\n${tail('${rn.stdout}\n${rn.stderr}')}');
    }
    final reportFile = File(p.join(srcDir, 'rename_report.json'));
    final Map<String, Object?> report;
    try {
      report = jsonDecode(reportFile.readAsStringSync()) as Map<String, Object?>;
    } on Object {
      throw CliException('pkg_rename wrote no valid rename_report.json.');
    }
    final renames = ((report['renames'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));
    final expected = {for (final x in spec.packages) x: spec.renamed(x)};
    if (canonical(renames) != canonical(expected)) {
      throw CliException('pkg_rename renamed ${renames.keys.join(', ')}, expected ${expected.keys.join(', ')}.');
    }
    final warnings = ((report['rewrite'] as Map?)?['warnings'] as List?)?.cast<String>() ?? const [];
    for (final w in warnings) {
      log('  warning (pkg_rename): $w');
    }

    // 3. Package config: the store build's resolution plus the renamed copies, canonical paths.
    final base = readPackageConfig(spec.appPackageConfig);
    final langOf = {for (final b in base) b.name: b.json['languageVersion']};
    final entries = <ConfigPackage>[
      for (final b in base) b,
      for (final e in renames.entries)
        ConfigPackage(e.value, _real(p.join(srcDir, e.value)), {
          'name': e.value,
          'rootUri': '',
          'packageUri': 'lib/',
          if (langOf[e.key] != null) 'languageVersion': langOf[e.key],
        }),
      ConfigPackage(spec.moduleName, _real(p.join(srcDir, spec.moduleName)), {
        'name': spec.moduleName,
        'rootUri': '',
        'packageUri': 'lib/',
        'languageVersion': '3.8',
      }),
    ];
    final configPath = p.join(srcDir, spec.moduleName, '.dart_tool', 'package_config.json');
    Directory(p.dirname(configPath)).createSync(recursive: true);
    File(configPath).writeAsStringSync(canonicalPackageConfig(entries, spec.mapping));
    String canon(String real) => spec.mapping.map(_real(real)) ?? real;
    // Packages the module resolves from the store build: only those that ARE in the store build
    // (host_packages.json "all"). Other entries of the package config (dev dependencies,
    // platform-only packages such as web/ffi/path_provider_windows) are never compiled for
    // Android and must not be claimed in the manifest, or the device refuses the patch.
    final storeBuild = _storeBuildPackages(spec.hostPackagesJson);
    final hostPkgs = [
      for (final b in base)
        if (!renames.containsKey(b.name) && storeBuild.contains(b.name)) b.name,
    ]..sort();

    // 4. Guard.
    log('  patch_guard: analysing the module sources');
    final guardJson = p.join(spec.workDir, 'guard.json');
    final g = await _tool(tools.patchGuard, [
      '--root',
      canon(srcDir),
      '--package-config',
      canon(configPath),
      '--module-packages',
      [spec.moduleName, ...renames.values].join(','),
      '--host-packages',
      spec.hostPackagesJson,
      '--original-names',
      renames.entries.map((e) => '${e.value}=${e.key}').join(','),
      '--sdk',
      p.join(spec.canonicalFlutterSdk, 'bin', 'cache', 'dart-sdk'),
      '--json',
      guardJson,
    ]);
    Map<String, Object?>? guardReport;
    try {
      guardReport = jsonDecode(File(guardJson).readAsStringSync()) as Map<String, Object?>;
    } on Object {
      guardReport = null;
    }
    if (g.exitCode == patchGuardRejected) {
      throw CliException('The patch was rejected by the security guard:\n${tail(g.stderr, 40)}', exitCode: 4);
    }
    if (g.exitCode != 0 || guardReport?['accepted'] != true) {
      throw CliException('patch_guard failed (exit ${g.exitCode}):\n${tail('${g.stdout}\n${g.stderr}')}');
    }

    // 5. Compile.
    log('  dart2bytecode: compiling against the release kernel and interface');
    final module = p.join(spec.workDir, 'module.bc');
    final c = await _tool(tools.dart2bytecode, [
      '--target',
      'flutter',
      '--platform',
      p.join(
        spec.canonicalFlutterSdk,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk_product',
        'platform_strong.dill',
      ),
      '--import-dill',
      spec.linkDill,
      '--validate',
      spec.dynamicInterface,
      '--packages',
      canon(configPath),
      '-o',
      module,
      canon(p.join(srcDir, spec.moduleName, 'lib', 'entry.dart')),
    ]);
    if (c.exitCode != 0 || !File(module).existsSync() || File(module).lengthSync() == 0) {
      final out = '${c.stdout}\n${c.stderr}';
      final hint = out.contains('in a dynamic module')
          ? '\nHint: the patch uses a class of the store build in a way the dynamic interface does not allow '
                '(for example extending it). If it comes from freezed_annotation, see docs/feature-patching.md.'
          : '';
      throw CliException('dart2bytecode failed (exit ${c.exitCode}):\n${tail(out)}$hint');
    }

    // 6. Reference verifier.
    String? verifierOutput;
    if (tools.bcVerify != null) {
      log('  bc_verify: checking the bytecode with the reference verifier');
      final v = await _tool(tools.bcVerify!, [module]);
      if (v.exitCode != 0 || !v.stdout.trimLeft().startsWith('OK')) {
        throw CliException(
          'The reference bytecode verifier rejected the module:\n${tail('${v.stdout}\n${v.stderr}')}',
          exitCode: 4,
        );
      }
      verifierOutput = v.stdout.trim();
    } else if (requireVerifier) {
      throw CliException(
        'The reference bytecode verifier (bc_verify) is not available: the toolchain has no '
        'tools/bc_verify.aot. Patches are never uploaded without it. Install a toolchain that ships it '
        '(toolchain builders only: set FLUTTER_OTA_BC_VERIFY to a bc_verify AOT snapshot), or use --dry-run.',
      );
    }

    final versions = <String, String>{};
    for (final x in spec.packages) {
      final v = spec.local[x]?.pubspec['version'];
      versions[x] = v is String && RegExp(r'^[0-9A-Za-z.+-]{1,64}$').hasMatch(v) ? v : '0.0.0';
    }
    return BuiltModule(
      modulePath: module,
      renames: renames,
      hostPackages: hostPkgs,
      guardReport: guardReport,
      verifierOutput: verifierOutput,
      packageVersions: versions,
    );
  }

  static String canonical(Map<String, String> m) =>
      jsonEncode(Map.fromEntries(m.entries.toList()..sort((a, b) => a.key.compareTo(b.key))));

  static String _real(String path) {
    final d = Directory(path);
    return d.existsSync() ? d.resolveSymbolicLinksSync() : p.normalize(p.absolute(path));
  }

  /// The packages of the store build: `all` of the release's host_packages.json.
  static Set<String> _storeBuildPackages(String hostPackagesJson) {
    final j = jsonDecode(File(hostPackagesJson).readAsStringSync());
    final all = j is Map ? j['all'] : j;
    if (all is! List) throw CliException('$hostPackagesJson: expected {"all": [...]}');
    return all.cast<String>().toSet();
  }
}
