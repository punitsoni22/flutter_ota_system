// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/features/discovery.dart';
import 'package:flutter_ota_cli/src/features/generator.dart';
import 'package:flutter_ota_cli/src/features/package_graph.dart';
import 'package:flutter_ota_cli/src/features/snapshot.dart';
import 'package:flutter_ota_cli/src/patch/planner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'patch_support.dart';

const host = {
  'shop',
  'core',
  'products',
  'products_data',
  'cart',
  'analytics',
  'legacy',
  'flutter_ota_system',
  'collection',
};

void main() {
  late FixtureProject f;
  late String releaseDir;

  setUp(() {
    f = FixtureProject.create();
    generateFeatureRegistry(f.app);
    releaseDir = p.join(f.root, 'release');
    recordFeatureSnapshot(f.app, releaseDir);
  });
  tearDown(() => f.dispose());

  PatchPlan plan() {
    final g = FeatureGraph.build(ProjectPackages.load(f.app));
    final diff = diffFeatureSnapshots(loadFeatureSnapshot(releaseDir), captureFeatureSnapshot(f.app));
    return planPatch(g, diff, host);
  }

  test('no change: empty plan', () {
    final pl = plan();
    expect(pl.refusals, isEmpty);
    expect(pl.isEmpty, isTrue);
  });

  test('feature change: the feature plus every feature that depends on it (closure)', () {
    f.edit('packages/products/lib/products.dart', (s) => s.replaceFirst("'products: ", "'products v2: "));
    final pl = plan();
    expect(pl.refusals, isEmpty);
    expect(pl.changed, {'products'});
    expect(pl.packages, {'products', 'cart'});
    expect(pl.features, ['cart', 'products']);
    expect(pl.why['cart'], contains('depends on products'));
    expect(pl.why['products'], contains('lib/products.dart'));
  });

  test('feature-internal change pulls in its feature and dependents', () {
    f.edit('packages/products_data/lib/products_data.dart', (s) => s.replaceFirst("'b'", "'c'"));
    final pl = plan();
    expect(pl.refusals, isEmpty);
    expect(pl.packages, {'products_data', 'products', 'cart'});
  });

  test('a leaf feature change patches only that feature', () {
    f.edit('packages/cart/lib/cart.dart', (s) => s.replaceFirst('=> start', '=> start + 1'));
    final pl = plan();
    expect(pl.packages, {'cart'});
    expect(pl.features, ['cart']);
  });

  test('freezed-style part file change counts as a source change', () {
    f.edit('packages/products/lib/src/model.g.dart', (s) => s.replaceFirst("'name'", "'title'"));
    expect(plan().changed, {'products'});
  });

  void expectRefused(String pattern) {
    final pl = plan();
    expect(pl.refusals.join('\n'), contains(pattern));
  }

  test('shared contract package change is refused', () {
    f.edit('packages/core/lib/src/money.dart', (s) => s.replaceFirst('cents', 'amount'));
    expectRefused('core is a shared (host-owned) package (used directly by the app) and changed');
  });

  test('shared model used by two features is refused', () {
    f.edit('packages/analytics/lib/analytics.dart', (s) => '$s// changed\n');
    expectRefused('analytics is a shared (host-owned) package (used by 2 features (cart, products))');
  });

  test('app package change is refused', () {
    f.edit('lib/main.dart', (s) => '$s// changed\n');
    expectRefused('the app package shop changed (1 file(s) changed: lib/main.dart)');
  });

  test('native code, assets and pubspec flutter: changes are refused', () {
    f.write('packages/cart/android/src/Main.kt', 'class Main\n');
    expectRefused('cart: native code changed');
    File(p.join(f.pkg('cart'), 'android', 'src', 'Main.kt')).deleteSync();
    f.write('packages/cart/assets/a.json', '{}');
    expectRefused('cart: files outside lib/ changed');
  });

  test('raising Android build tool versions and a new toolchain pin do not block a patch', () {
    // What `flutter_ota upgrade` to a newer Flutter needs: the release stays patchable.
    f.write('android/gradle/wrapper/gradle-wrapper.properties', 'distributionUrl=gradle-9.1.0-all.zip\n');
    f.write('android/settings.gradle.kts', 'id("com.android.application") version "9.0.1"\n');
    f.write('flutter_ota.lock', 'toolchain: "flutter-3.47.9-ota.1"\n');
    recordFeatureSnapshot(f.app, releaseDir);
    f.write('android/gradle/wrapper/gradle-wrapper.properties', 'distributionUrl=gradle-9.5.0-all.zip\n');
    f.write('android/settings.gradle.kts', 'id("com.android.application") version "9.3.1"\n');
    f.write('flutter_ota.lock', 'toolchain: "flutter-3.50.0-ota.1"\n');
    expect(plan().refusals, isEmpty);
    // Any other native change in the app is still refused.
    f.write('android/app/build.gradle.kts', 'android { }\n');
    expectRefused('native code changed');
  });

  test('a snapshot without per-file hashes (older releases) keeps the strict group rule', () {
    f.write('android/settings.gradle.kts', 'id("com.android.application") version "9.0.1"\n');
    recordFeatureSnapshot(f.app, releaseDir);
    final file = File(p.join(releaseDir, 'feature_snapshot.json'));
    final snap = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    for (final pkg in (snap['packages']! as Map).values) {
      (pkg as Map)
        ..remove('native_files')
        ..remove('other_hashes');
    }
    file.writeAsStringSync(jsonEncode(snap));
    f.write('android/settings.gradle.kts', 'id("com.android.application") version "9.3.1"\n');
    expectRefused('native code changed');
  });

  test('new dependency outside the store build is refused; one inside is a note', () {
    f.edit('packages/cart/pubspec.yaml', (s) => '$s  http: ^1.0.0\n');
    expectRefused('cart: new dependencies http are not part of the store build');
    f.edit('packages/cart/pubspec.yaml', (s) => s.replaceFirst('  http: ^1.0.0\n', '  collection: ^1.19.0\n'));
    final pl = plan();
    expect(pl.refusals, isEmpty);
    expect(pl.notes.join(), contains('cart now also depends on collection'));
    expect(pl.packages, {'cart'});
  });

  test('pubspec.lock and registry changes are refused', () {
    f.edit('pubspec.lock', (s) => s.replaceFirst('1.19.1', '1.19.2'));
    expectRefused('pubspec.lock changed since the release');
    f.edit('pubspec.lock', (s) => s.replaceFirst('1.19.2', '1.19.1'));
    f.edit('lib/flutter_ota_features.g.dart', (s) => '$s// x\n');
    expectRefused('lib/flutter_ota_features.g.dart changed');
  });

  test('new package is refused', () {
    f.write('packages/extra/pubspec.yaml', 'name: extra\n');
    f.write('packages/extra/lib/extra.dart', 'int x = 1;\n');
    f.edit('packages/cart/pubspec.yaml', (s) => '$s  extra:\n    path: ../extra\n');
    f.writePackageConfig();
    expectRefused('extra is a new package that is not in the store build');
  });

  test('snapshot records roles, entries and files', () {
    final s = loadFeatureSnapshot(releaseDir);
    final pk = (s['packages']! as Map)['products'] as Map;
    expect(pk['role'], 'feature');
    expect((pk['entry'] as Map)['class'], 'ProductsFeature');
    expect((pk['files'] as Map).keys, containsAll(['lib/products.dart', 'lib/src/model.g.dart']));
    expect(((s['packages']! as Map)['shop'] as Map)['other_files'], ['assets/logo.txt', 'flutter_ota.yaml']);
    expect(() => loadFeatureSnapshot(f.root), throwsA(isA<CliException>()));
  });
}
