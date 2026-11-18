// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Redirect engine (EXPERIMENTAL): release baseline, patch generation with the real ota_redirect
// tool (prototypes/redirect_stubs), and the module build from a ready module package.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_ota_cli/src/build_support/canonical_paths.dart';
import 'package:flutter_ota_cli/src/build_support/dynamic_interface.dart';
import 'package:flutter_ota_cli/src/errors.dart';
import 'package:flutter_ota_cli/src/features/snapshot.dart';
import 'package:flutter_ota_cli/src/patch/module_builder.dart';
import 'package:flutter_ota_cli/src/patch/process.dart';
import 'package:flutter_ota_cli/src/redirect/redirect_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'patch_support.dart';

final _repo = p.normalize(p.join(Directory.current.path, '..', '..'));
final _toolDir = p.join(_repo, 'prototypes', 'redirect_stubs', 'tool');
final _cases = p.join(_repo, 'prototypes', 'redirect_stubs', 'cases');
final _dart = Platform.resolvedExecutable;

void _copy(String from, String to) {
  final r = Process.runSync('cp', ['-R', from, to]);
  if (r.exitCode != 0) throw StateError('cp failed: ${r.stderr}');
}

void _pubGet(String dir) {
  final r = Process.runSync(_dart, ['pub', 'get', '--offline'], workingDirectory: dir);
  if (r.exitCode != 0) {
    final r2 = Process.runSync(_dart, ['pub', 'get'], workingDirectory: dir);
    if (r2.exitCode != 0) throw StateError('pub get in $dir failed: ${r2.stderr}');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('flutter_ota_redirect_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('engine selection', () {
    test('the tool folder must be set and contain bin/ota_redirect.dart', () {
      expect(() => redirectToolDir({}), throwsA(isA<CliException>()));
      expect(() => redirectToolDir({redirectToolEnv: tmp.path}), throwsA(isA<CliException>()));
      expect(redirectToolDir({redirectToolEnv: _toolDir}), p.normalize(_toolDir));
    });
  });

  group('dynamic interface: private classes reached through type aliases', () {
    const libs = ['dart:core', 'dart:async', 'package:shop/main.dart', 'package:shop/src/a.dart'];

    test('without private classes the file is exactly the policy-2 file', () {
      final plain = buildDynamicInterface(libs);
      expect(buildDynamicInterface(libs, privateClasses: const []).yaml, plain.yaml);
      expect(plain.yaml, isNot(contains('class:')));
    });

    test('each private class is listed by name in every section, sorted and once', () {
      final iface = buildDynamicInterface(
        libs,
        privateClasses: [
          (library: 'package:shop/src/a.dart', className: '_Mode'),
          (library: 'package:shop/src/a.dart', className: '_Calc'),
          (library: 'package:shop/src/a.dart', className: '_Calc'),
        ],
      );
      const entries =
          "  - library: 'package:shop/src/a.dart'\n    class: '_Calc'\n"
          "  - library: 'package:shop/src/a.dart'\n    class: '_Mode'\n";
      expect(entries.allMatches(iface.yaml).length, 4, reason: iface.yaml);
      for (final s in ['callable:', 'can-be-used-as-type:', 'extendable:', 'can-be-overridden:']) {
        expect(iface.yaml, contains('$s\n'));
      }
    });

    test('entries of unlisted libraries, public names and dart: libraries are dropped', () {
      final iface = buildDynamicInterface(
        libs,
        exclude: {'package:shop/main.dart'},
        privateClasses: [
          (library: 'package:shop/main.dart', className: '_Hidden'),
          (library: 'package:other/x.dart', className: '_X'),
          (library: 'package:shop/src/a.dart', className: 'Public'),
          (library: 'dart:core', className: '_StringBase'),
        ],
      );
      expect(iface.yaml, isNot(contains('class:')));
    });

    test('the experimental app scope keeps only the app package and the dart: libraries', () {
      final iface = buildDynamicInterface(
        [...libs, 'package:flutter/widgets.dart', 'package:collection/collection.dart'],
        onlyPackages: {'shop'},
      );
      expect(iface.libraries, ['dart:async', 'dart:core', 'package:shop/main.dart', 'package:shop/src/a.dart']);
      expect(iface.yaml, contains('# EXPERIMENTAL scope: only the packages shop.'));
      expect(buildDynamicInterface(libs, onlyPackages: null).yaml, buildDynamicInterface(libs).yaml);
    });

    test('the manifest lists them; older manifests have none', () {
      final m = File(p.join(tmp.path, 'm.json'));
      m.writeAsStringSync(
        jsonEncode({
          'private_types': [
            {'library': 'package:shop/src/a.dart', 'class': '_Calc'},
          ],
        }),
      );
      expect(redirectPrivateClasses(m.path), [(library: 'package:shop/src/a.dart', className: '_Calc')]);
      m.writeAsStringSync(jsonEncode({'slots': {}}));
      expect(redirectPrivateClasses(m.path), isEmpty);
      m.writeAsStringSync(
        jsonEncode({
          'private_types': [42],
        }),
      );
      expect(() => redirectPrivateClasses(m.path), throwsA(isA<CliException>()));
    });
  });

  group('what the redirect engine refuses', () {
    Map<String, Object?> pkg({
      Map<String, String> files = const {},
      Map<String, Object?> deps = const {},
      String native = 'n',
      String other = 'o',
      String flutter = 'f',
    }) => {
      'files': files,
      'dependencies': deps,
      'flutter_sha256': flutter,
      'environment': {'sdk': '^3.8.0'},
      'native_files': {'android/x': native},
      'other_hashes': {'assets/a': other},
    };
    Map<String, Object?> snap(Map<String, Object?> packages, {String lock = 'L'}) => {
      'lock_sha256': lock,
      'registry_sha256': 'R',
      'packages': packages,
    };
    final release = snap({
      'shop': pkg(
        files: {'lib/a.dart': '1'},
        deps: {
          'core': {'path': 'packages/core'},
        },
      ),
      'core': pkg(files: {'lib/c.dart': '1'}),
    });

    test('a change of Dart code in the app package is patchable', () {
      final now = snap({
        'shop': pkg(
          files: {'lib/a.dart': '2', 'lib/new.dart': '1'},
          deps: {
            'core': {'path': 'packages/core'},
          },
        ),
        'core': pkg(files: {'lib/c.dart': '1'}),
      });
      final (refusals, notes) = redirectRefusals(diffFeatureSnapshots(release, now), 'shop', {'shop', 'core'});
      expect(refusals, isEmpty);
      expect(notes, isEmpty);
    });

    test('a change in another local package is refused, not silently left out', () {
      final now = snap({
        'shop': pkg(
          files: {'lib/a.dart': '1'},
          deps: {
            'core': {'path': 'packages/core'},
          },
        ),
        'core': pkg(files: {'lib/c.dart': '2'}),
      });
      final (refusals, _) = redirectRefusals(diffFeatureSnapshots(release, now), 'shop', {'shop', 'core'});
      expect(refusals.single, contains('patches only the app package shop'));
    });

    test('native code, assets, the flutter section, the lock file and new dependencies are refused', () {
      final now = snap({
        'shop': pkg(
          files: {'lib/a.dart': '1'},
          deps: {
            'core': {'path': 'packages/core'},
            'left_pad': '^1.0.0',
          },
          native: 'n2',
          other: 'o2',
          flutter: 'f2',
        ),
        'core': pkg(files: {'lib/c.dart': '1'}),
      }, lock: 'L2');
      final (refusals, _) = redirectRefusals(diffFeatureSnapshots(release, now), 'shop', {'shop', 'core'});
      expect(
        refusals.join('\n'),
        allOf(
          contains('pubspec.lock'),
          contains('native code'),
          contains('outside lib/'),
          contains('`flutter:`'),
          contains('left_pad'),
        ),
      );
    });
  });

  group('baseline', () {
    late String project;
    late String instrumented;
    late String release;

    setUp(() {
      project = p.join(tmp.path, 'project');
      instrumented = p.join(tmp.path, 'build_copy');
      release = p.join(tmp.path, 'release');
      for (final d in [project, instrumented]) {
        Directory(p.join(d, 'lib')).createSync(recursive: true);
        File(p.join(d, 'pubspec.yaml')).writeAsStringSync('name: shop\n');
        File(p.join(d, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {'name': 'shop', 'rootUri': '../', 'packageUri': 'lib/'},
                {'name': 'core', 'rootUri': '../packages/core', 'packageUri': 'lib/'},
                {'name': 'meta', 'rootUri': 'file:///pub/meta', 'packageUri': 'lib/'},
              ],
            }),
          );
      }
      File(p.join(project, 'lib', 'main.dart')).writeAsStringSync('int f() => 1;\n');
      File(p.join(instrumented, 'lib', 'main.dart')).writeAsStringSync('int f() => ota\$s1 != null ? 0 : 1;\n');
      File(p.join(instrumented, 'ota_manifest.json')).writeAsStringSync('{"slots": {}}');
      Directory(release).createSync();
    });

    test('keeps the source, the instrumented source and the manifest', () {
      saveRedirectBaseline(projectDir: project, instrumentedApp: instrumented, releaseDir: release);
      final b = RedirectBaseline(release)..check();
      expect(File(p.join(b.source, 'lib', 'main.dart')).readAsStringSync(), contains('=> 1'));
      expect(File(p.join(b.instrumented, 'lib', 'main.dart')).readAsStringSync(), contains('ota\$s1'));
      expect(File(b.manifest).readAsStringSync(), '{"slots": {}}');
      expect(pubspecName(p.join(b.source, 'pubspec.yaml')), 'shop');
    });

    test('each copy resolves the app package to itself and keeps the real dependencies', () {
      saveRedirectBaseline(projectDir: project, instrumentedApp: instrumented, releaseDir: release);
      final b = RedirectBaseline(release);
      for (final dir in [b.source, b.instrumented]) {
        final cfg = readPackageConfig(p.join(dir, '.dart_tool', 'package_config.json'));
        final roots = {for (final c in cfg) c.name: c.root};
        expect(p.equals(roots['shop']!, Directory(dir).resolveSymbolicLinksSync()), isTrue);
        expect(p.equals(roots['core']!, p.join(project, 'packages', 'core')), isTrue, reason: roots['core']);
        expect(roots['meta'], '/pub/meta');
      }
    });

    test('a second save replaces the old baseline', () {
      saveRedirectBaseline(projectDir: project, instrumentedApp: instrumented, releaseDir: release);
      final stale = File(p.join(RedirectBaseline(release).source, 'lib', 'old.dart'))..writeAsStringSync('');
      saveRedirectBaseline(projectDir: project, instrumentedApp: instrumented, releaseDir: release);
      expect(stale.existsSync(), isFalse);
    });

    test('an incomplete baseline is refused', () {
      saveRedirectBaseline(projectDir: project, instrumentedApp: instrumented, releaseDir: release);
      File(RedirectBaseline(release).manifest).deleteSync();
      expect(
        () => RedirectBaseline(release).check(),
        throwsA(isA<CliException>().having((e) => e.message, 'message', contains('ota_manifest.json'))),
      );
    });
  });

  group('module build from a module package', () {
    test('guards only the module package against the instrumented app, then compiles its entry', () async {
      final root = Directory(tmp.path).resolveSymbolicLinksSync();
      final app = p.join(root, 'project');
      final inst = p.join(root, 'release', 'redirect', 'instrumented');
      final work = p.join(root, 'canon', 'patch', 'ota_patch_3');
      final mod = p.join(work, 'src', 'ota_patch_3');
      for (final d in [p.join(app, 'lib'), p.join(inst, 'lib'), p.join(mod, 'lib')]) {
        Directory(d).createSync(recursive: true);
      }
      File(p.join(mod, 'lib', 'entry.dart')).writeAsStringSync('// entry\n');
      final cfg = p.join(app, '.dart_tool', 'package_config.json');
      File(cfg)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'shop', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.8'},
              {'name': 'flutter_test', 'rootUri': '../', 'packageUri': 'lib/'},
            ],
          }),
        );
      final host = p.join(root, 'host_packages.json');
      File(host).writeAsStringSync(
        jsonEncode({
          'all': ['shop'],
          'internal': ['shop'],
        }),
      );

      final tools = FakeTools();
      tools.handlers['patch_guard'] = (c) {
        File(c.opt('--json')!).writeAsStringSync(jsonEncode({'accepted': true, 'findings': []}));
        return ToolResult(0, '', '');
      };
      tools.handlers['dart2bytecode'] = (c) {
        File(c.opt('-o')!).writeAsBytesSync([1, 2, 3]);
        return ToolResult(0, '', '');
      };
      tools.handlers['bc_verify'] = (c) => ToolResult(0, 'OK 1 library', '');
      final built =
          await ModuleBuilder(
            tools: PatchTools(
              flutterSdk: p.join(root, 'sdk'),
              dartAotRuntime: p.join(root, 'dartaotruntime'),
              dart2bytecode: p.join(root, 'dart2bytecode.aot'),
              pkgRename: p.join(root, 'pkg_rename.aot'),
              patchGuard: p.join(root, 'patch_guard.aot'),
              bcVerify: p.join(root, 'bc_verify.aot'),
            ),
            run: tools.call,
            log: (_) {},
          ).buildPackage(
            moduleName: 'ota_patch_3',
            moduleDir: mod,
            appName: 'shop',
            appRoot: inst,
            appPackageConfig: cfg,
            hostPackagesJson: host,
            linkDill: '/canon/link.dill',
            dynamicInterface: '/canon/dynamic_interface.yaml',
            workDir: work,
            mapping: PathMapping({root: '/canon-root'}),
            canonicalFlutterSdk: '/canon-root/sdk',
          );

      expect(tools.toolNames, ['patch_guard', 'dart2bytecode', 'bc_verify']);
      final guard = tools.calls[0];
      expect(guard.opt('--module-packages'), 'ota_patch_3');
      expect(
        guard.opt('--package-config'),
        '/canon-root/canon/patch/ota_patch_3/src/ota_patch_3/.dart_tool/package_config.json',
      );
      final compile = tools.calls[1];
      expect(compile.opt('--import-dill'), '/canon/link.dill');
      expect(compile.opt('--validate'), '/canon/dynamic_interface.yaml');
      expect(compile.args.last, '/canon-root/canon/patch/ota_patch_3/src/ota_patch_3/lib/entry.dart');

      final written = jsonDecode(File(p.join(mod, '.dart_tool', 'package_config.json')).readAsStringSync()) as Map;
      final roots = {for (final e in (written['packages'] as List).cast<Map>()) e['name']: e['rootUri']};
      expect(roots['shop'], 'file:///canon-root/release/redirect/instrumented/');
      expect(roots['ota_patch_3'], 'file:///canon-root/canon/patch/ota_patch_3/src/ota_patch_3/');
      expect(built.renames, isEmpty);
      expect(built.hostPackages, ['shop'], reason: 'dev dependencies are not claimed as host packages');
      expect(built.verifierOutput, 'OK 1 library');
    });

    test('a module package outside the work directory is refused', () async {
      final b = ModuleBuilder(
        tools: PatchTools(
          flutterSdk: '/s',
          dartAotRuntime: '/r',
          dart2bytecode: '/d',
          pkgRename: '/k',
          patchGuard: '/g',
        ),
        run: FakeTools().call,
        log: (_) {},
      );
      expect(
        () => b.buildPackage(
          moduleName: 'ota_patch_1',
          moduleDir: p.join(tmp.path, 'elsewhere'),
          appName: 'shop',
          appRoot: tmp.path,
          appPackageConfig: '/none',
          hostPackagesJson: '/none',
          linkDill: '/l',
          dynamicInterface: '/i',
          workDir: p.join(tmp.path, 'work'),
          mapping: PathMapping({}),
          canonicalFlutterSdk: '/s',
        ),
        throwsA(isA<CliException>()),
      );
    });
  });

  group('ota_redirect tool (Shot 1 cases)', () {
    final available =
        Directory(p.join(_cases, 'v1')).existsSync() && File(p.join(_toolDir, 'bin', 'ota_redirect.dart')).existsSync();

    test(
      'release baseline, then a patch for the v2 change: module package with an entry, no refusals',
      () async {
        final env = Platform.environment;
        final project = p.join(tmp.path, 'project');
        final buildCopy = p.join(tmp.path, 'build_copy');
        final release = p.join(tmp.path, 'release');
        _copy(p.join(_cases, 'v1'), project);
        _pubGet(project);
        _copy(project, buildCopy);
        _pubGet(buildCopy);
        Directory(release).createSync();

        // Release: instrument the build copy, keep the baseline.
        final out = await runRedirectTool(
          dartBin: _dart,
          toolDir: _toolDir,
          args: ['instrument', buildCopy],
          environment: env,
        );
        expect(out, contains('guards'));
        saveRedirectBaseline(projectDir: project, instrumentedApp: buildCopy, releaseDir: release);
        final baseline = RedirectBaseline(release)..check();
        // The private classes the patch of privates.dart reaches (the Shot 2 compile error).
        expect(
          redirectPrivateClasses(baseline.manifest),
          containsAll([
            (library: 'package:app/src/privates.dart', className: '_Calc'),
            (library: 'package:app/src/privates.dart', className: '_Mode'),
          ]),
        );

        // No change yet: nothing to patch.
        final none = await generateRedirectPatch(
          dartBin: _dart,
          toolDir: _toolDir,
          baseline: baseline,
          projectDir: project,
          outDir: p.join(tmp.path, 'work0', 'ota_patch_1'),
          moduleName: 'ota_patch_1',
          environment: env,
        );
        expect(none.isEmpty, isTrue);
        expect(none.level, 0);

        // The developer changes the app (v2), then builds a patch.
        Directory(p.join(project, 'lib')).deleteSync(recursive: true);
        _copy(p.join(_cases, 'v2', 'lib'), p.join(project, 'lib'));
        final src = await generateRedirectPatch(
          dartBin: _dart,
          toolDir: _toolDir,
          baseline: baseline,
          projectDir: project,
          outDir: p.join(tmp.path, 'work', 'ota_patch_1'),
          moduleName: 'ota_patch_1',
          environment: env,
        );
        expect(src.isEmpty, isFalse);
        expect(src.refused, isEmpty);
        expect(src.level, inInclusiveRange(1, 3));
        expect(src.list('patched'), isNotEmpty);
        final entry = File(p.join(src.packageDir, 'lib', 'entry.dart')).readAsStringSync();
        expect(entry, contains("@pragma('dyn-module:entry-point')"));
        expect(entry, contains('otaInstall();'));
        expect(File(p.join(src.packageDir, 'pubspec.yaml')).readAsStringSync(), contains('name: ota_patch_1'));
      },
      skip: available ? false : 'prototypes/redirect_stubs is not in this checkout',
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
