// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/features/discovery.dart';
import 'package:flutter_ota_cli/src/features/generator.dart';
import 'package:flutter_ota_cli/src/features/package_graph.dart';
import 'package:flutter_ota_cli/src/patch/module_builder.dart';
import 'package:flutter_ota_cli/src/release/ota_entry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'patch_support.dart';

final demoDir = p.normalize(p.join(Directory.current.path, '..', 'ota_client', 'example'));
final goldenDir = p.join(fixturesDir, 'golden');

void main() {
  test('reproduces the demo app registry byte for byte', () {
    final cfg = File(p.join(demoDir, '.dart_tool', 'package_config.json'));
    if (!cfg.existsSync()) {
      markTestSkipped('the demo app has no package config (run flutter pub get in ${p.relative(demoDir)})');
      return;
    }
    final graph = FeatureGraph.build(ProjectPackages.load(demoDir));
    expect(graph.problems, isEmpty);
    expect(graph.roles['products'], PackageRole.feature);
    expect(graph.roles['core'], PackageRole.shared);
    expect(renderRegistry(graph), File(p.join(demoDir, 'lib', registryFileName)).readAsStringSync());
  });

  group('shop fixture', () {
    late FixtureProject f;
    setUp(() => f = FixtureProject.create());
    tearDown(() => f.dispose());

    test('registry golden (OtaFeature and a shared-package contract, prefixed imports)', () {
      final r = generateFeatureRegistry(f.app);
      expect(r.changed, isTrue);
      final golden = File(p.join(goldenDir, 'shop_registry.g.dart.golden')).readAsStringSync();
      expect(File(r.path).readAsStringSync(), golden);
      // Getter names never equal an import prefix (a getter would hide the prefix).
      expect(golden, isNot(contains(' as products;')));
      expect(generateFeatureRegistry(f.app).changed, isFalse);
      expect(generateFeatureRegistry(f.app, check: true).changed, isFalse);
    });

    test('check mode reports a stale registry and writes nothing', () {
      generateFeatureRegistry(f.app);
      f.edit('pubspec.yaml', (s) => s.replaceFirst('  cart:\n    path: packages/cart\n', ''));
      f.edit('packages/cart/lib/cart.dart', (s) => s.replaceFirst('CartFeature', 'CartThing'));
      f.edit('packages/cart/lib/cart.dart', (s) => s.replaceFirst('CartFeature(', 'CartThing('));
      final before = File(p.join(f.app, 'lib', registryFileName)).readAsStringSync();
      final r = generateFeatureRegistry(f.app, check: true);
      expect(r.changed, isTrue);
      expect(File(r.path).readAsStringSync(), before);
    });

    test('refuses to generate while the graph has problems', () {
      f.write('packages/cart/lib/src/base.dart', 'abstract class CartBase { int count(); }\n');
      expect(
        () => generateFeatureRegistry(f.app),
        throwsA(isA<CliException>().having((e) => e.message, 'message', contains('no host-owned supertype'))),
      );
    });

    test('module entry golden (contract 3)', () {
      final g = FeatureGraph.build(ProjectPackages.load(f.app));
      final entry = renderModuleEntry([g.features['products']!, g.features['cart']!]);
      expect(entry, File(p.join(goldenDir, 'module_entry.dart.golden')).readAsStringSync());
    });

    test('CLI: flutter_ota features prints the graph; generate writes the file', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final ctx = CliContext(environment: {'HOME': f.root}, workingDirectory: f.app, out: out, err: err);
      expect(await runCli(['features'], context: ctx), 0);
      final text = out.toString();
      expect(text, contains('products  packages/products'));
      expect(text, contains('entry CartFeature (lib/cart.dart) -> OtaFeatures.cart : CartApi from core'));
      expect(text, contains('patched together with: products_data'));
      expect(text, contains('analytics  used by 2 features (cart, products)'));
      expect(text, contains('cart [feature] -> analytics, core, products'));
      out.clear();
      expect(await runCli(['features', 'generate'], context: ctx), 0);
      expect(out.toString(), contains('Wrote lib/flutter_ota_features.g.dart (2 feature slot(s))'));
      expect(await runCli(['features', 'generate', '--check'], context: ctx), 0);
    });

    group('entry wrapper lib/$otaMainFileName (owned by the release command)', () {
      String entry() => File(p.join(f.app, 'lib', otaMainFileName)).readAsStringSync();

      test('is never created by the features generator', () {
        final r = generateFeatureRegistry(f.app);
        expect(r.entryPath, isNull);
        expect(File(p.join(f.app, 'lib', otaMainFileName)).existsSync(), isFalse);
      });

      test('the release output is up to date for `features generate --check` (same renderer)', () async {
        writeOtaMain(f.app); // exactly what `release android` writes
        final releaseBytes = entry();
        expect(releaseBytes, renderOtaMain(mainTakesArgs: false));
        final r = generateFeatureRegistry(f.app);
        expect(r.entryChanged, isFalse);
        expect(entry(), releaseBytes);
        final ctx = CliContext(
          environment: {'HOME': f.root},
          workingDirectory: f.app,
          out: StringBuffer(),
          err: StringBuffer(),
        );
        expect(await runCli(['features', 'generate', '--check'], context: ctx), 0);
      });

      test('a stale or edited entry is reported by --check and re-rendered by generate', () async {
        generateFeatureRegistry(f.app);
        writeOtaMain(f.app);
        File(p.join(f.app, 'lib', otaMainFileName)).writeAsStringSync('// edited by hand\n');
        final out = StringBuffer();
        final ctx = CliContext(environment: {'HOME': f.root}, workingDirectory: f.app, out: out, err: out);
        expect(await runCli(['features', 'generate', '--check'], context: ctx), 1);
        expect(out.toString(), contains('OUT OF DATE (lib/$otaMainFileName)'));
        expect(entry(), '// edited by hand\n');
        expect(await runCli(['features', 'generate'], context: ctx), 0);
        expect(entry(), renderOtaMain(mainTakesArgs: false));
        expect(await runCli(['features', 'generate', '--check'], context: ctx), 0);
      });
    });
  });
}
