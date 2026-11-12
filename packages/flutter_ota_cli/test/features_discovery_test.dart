// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_ota_cli/src/features/dart_source.dart';
import 'package:flutter_ota_cli/src/features/discovery.dart';
import 'package:flutter_ota_cli/src/features/package_graph.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'patch_support.dart';

void main() {
  group('dart_source', () {
    test('directives: prefixes, combinators, conditional URIs; comments ignored', () {
      final d = parseDirectives('''
// import 'package:fake/commented.dart';
/* import 'package:fake/block.dart'; */
library;
import 'package:a/a.dart' as a show X, Y;
import "package:b/b.dart" hide Z;
export 'src/x.dart';
import 'stub.dart' if (dart.library.io) 'io.dart';
part 'x.g.dart';
class C { String s = "import 'package:not/real.dart';"; }
''');
      expect(d.map((x) => '${x.kind}:${x.uri}'), [
        'import:package:a/a.dart',
        'import:package:b/b.dart',
        'export:src/x.dart',
        'import:stub.dart',
        'import:io.dart',
        'part:x.g.dart',
      ]);
      expect(d[0].prefix, 'a');
      expect(d[0].show, ['X', 'Y']);
      expect(d[1].hide, ['Z']);
      expect(d[1].exposes('Z'), isFalse);
      expect(d[0].packageName, 'a');
    });

    test('top-level declarations, supertypes and constructors', () {
      final t = findTypeDeclarations(r'''
@immutable
abstract base class A<T> extends p.B<T> with M implements I, J<int> {
  const A();
  void f() { final x = 'class Fake {}'; }
}
mixin M {}
class D { D(int x, {required int y}); class_() {} }
typedef F = int Function();
enum E { a }
''');
      expect(t.map((x) => '${x.keyword} ${x.name}'), ['class A', 'mixin M', 'class D', 'typedef F', 'enum E']);
      expect(t[0].isAbstract, isTrue);
      expect(t[0].superclass, 'p.B');
      expect(t[0].interfaces, ['I', 'J']);
      expect(t[0].mixins, ['M']);
      expect(t[0].unnamedConstructorParameters, ['']);
      expect(hasRequiredParameter(t[2].unnamedConstructorParameters.single), isTrue);
      expect(hasRequiredParameter('[int x = 0]'), isFalse);
      expect(hasRequiredParameter('{int x = 0}'), isFalse);
    });

    test('names', () {
      expect(pascalCase('user_profile'), 'UserProfile');
      expect(camelCase('user_profile'), 'userProfile');
      expect(entryClassNames('feature_cart'), containsAll(['FeatureCartFeature', 'CartFeature']));
      expect(entryClassNames('cart_feature'), contains('CartFeature'));
    });
  });

  group('feature graph', () {
    late FixtureProject f;
    setUp(() => f = FixtureProject.create());
    tearDown(() => f.dispose());

    FeatureGraph graph() => FeatureGraph.build(ProjectPackages.load(f.app));

    test('classifies features, feature-internal and shared packages', () {
      final g = graph();
      expect(g.problems, isEmpty);
      expect(g.roles, {
        'shop': PackageRole.app,
        'products': PackageRole.feature,
        'cart': PackageRole.feature,
        'products_data': PackageRole.featureInternal,
        'core': PackageRole.shared,
        'analytics': PackageRole.shared,
        'legacy': PackageRole.shared,
      });
      expect(g.internalOwner, {'products_data': 'products'});
      expect(g.reasons['analytics']!.single, contains('used by 2 features (cart, products)'));
      expect(g.reasons['core']!.single, contains('used directly by the app'));
      expect(g.reasons['legacy']!.single, contains('imported directly by the app (lib/main.dart)'));
      expect(g.warnings.join('\n'), contains('legacy has a feature entry'));
    });

    test('contract: nearest host-owned supertype (SDK, or shared package through a local base)', () {
      final g = graph();
      final products = g.features['products']!;
      expect(products.className, 'ProductsFeature');
      expect(products.contractType, 'OtaFeature');
      expect(products.contractPackage, 'flutter_ota_system');
      expect(products.contractLibraryUri, 'package:flutter_ota_system/flutter_ota_system.dart');
      final cart = g.features['cart']!;
      expect(cart.contractType, 'CartApi');
      expect(cart.contractPackage, 'core');
      expect(cart.contractLibraryUri, 'package:core/core.dart');
    });

    test('a feature whose only supertype is its own is refused', () {
      f.write('packages/cart/lib/src/base.dart', 'abstract class CartBase { int count(); }\n');
      final g = graph();
      expect(g.problems.join('\n'), contains('CartFeature has no host-owned supertype'));
    });

    test('a contract type from another feature is not host-owned', () {
      f.write(
        'packages/products/lib/src/model.dart',
        "part 'model.g.dart';\nabstract class ProductsApi {}\nclass Product {}\n",
      );
      f.write('packages/products/lib/src/model.g.dart', "part of 'model.dart';\n");
      f.write(
        'packages/cart/lib/cart.dart',
        "import 'package:products/products.dart';\nclass CartFeature implements ProductsApi {}\n",
      );
      final g = graph();
      expect(g.problems.join('\n'), contains('CartFeature has no host-owned supertype'));
      expect(g.problems.join('\n'), contains('ProductsApi (feature package products)'));
    });

    test('entry class needs a no-argument constructor and must not be abstract', () {
      f.edit(
        'packages/cart/lib/cart.dart',
        (s) => s.replaceFirst('CartFeature({this.start = 0});', 'CartFeature(this.start);'),
      );
      expect(graph().problems.join('\n'), contains('needs an unnamed constructor without required arguments'));
      f.edit('packages/cart/lib/cart.dart', (s) => s.replaceFirst('class CartFeature', 'abstract class CartFeature'));
      expect(graph().problems.join('\n'), contains('must not be abstract'));
    });

    test('a package without an entry class used by one feature is internal; by the app it is shared', () {
      expect(graph().roles['products_data'], PackageRole.featureInternal);
      f.edit('lib/main.dart', (s) => "import 'package:products_data/products_data.dart';\n$s");
      final g = graph();
      expect(g.roles['products_data'], PackageRole.shared);
      expect(g.reasons['products_data']!.single, contains('imported by the app'));
    });

    test('a feature used by a shared package is pinned (shared)', () {
      f.edit('packages/analytics/pubspec.yaml', (s) => '${s}dependencies:\n  products:\n    path: ../products\n');
      final g = graph();
      expect(g.roles['products'], PackageRole.shared);
      expect(g.reasons['products']!.single, contains('used by the shared package analytics'));
      // Its internal package follows it.
      expect(g.roles['products_data'], PackageRole.shared);
    });

    test('feature must be a direct dependency of the app', () {
      f.edit('pubspec.yaml', (s) => s.replaceFirst('  cart:\n    path: packages/cart\n', ''));
      expect(graph().problems.join('\n'), contains('the app does not depend on it directly'));
    });

    test('JSON graph lists dependencies and dependents', () {
      final j = graph().toJson();
      final pk = (j['packages']! as Map)['analytics'] as Map;
      expect(pk['role'], 'shared');
      expect(pk['used_by'], ['cart', 'products']);
      expect(((j['packages']! as Map)['cart'] as Map)['depends_on'], ['analytics', 'core', 'products']);
    });

    test('dynamic_modules and everything under .flutter_ota/ are host-owned, never features', () {
      // What `release android` sets up: the loader copied into .flutter_ota/packages, the app
      // depending on it and the generated entry importing it.
      f.write(
        '.flutter_ota/packages/dynamic_modules/pubspec.yaml',
        'name: dynamic_modules\nenvironment:\n  sdk: ^3.8.0\n',
      );
      f.write(
        '.flutter_ota/packages/dynamic_modules/lib/dynamic_modules.dart',
        'Future<Object?> loadModuleFromBytes(List<int> bytes) async => null;\n',
      );
      // Even a package there that looks exactly like a feature stays host-owned.
      f.write(
        '.flutter_ota/packages/sneaky/pubspec.yaml',
        'name: sneaky\nenvironment:\n  sdk: ^3.8.0\ndependencies:\n  flutter_ota_system:\n    path: ../../../../sdk/flutter_ota_system\n',
      );
      f.write(
        '.flutter_ota/packages/sneaky/lib/sneaky.dart',
        "import 'package:flutter_ota_system/flutter_ota_system.dart';\nclass SneakyFeature extends OtaFeature {}\n",
      );
      f.edit(
        'pubspec.yaml',
        (s) => s.replaceFirst(
          'dependencies:\n',
          'dependencies:\n  dynamic_modules:\n    path: .flutter_ota/packages/dynamic_modules\n'
              '  sneaky:\n    path: .flutter_ota/packages/sneaky\n',
        ),
      );
      f.write(
        'lib/flutter_ota_main.g.dart',
        "import 'package:dynamic_modules/dynamic_modules.dart' as dm;\nimport 'package:sneaky/sneaky.dart';\n",
      );
      f.writePackageConfig(
        extra: {
          'dynamic_modules': p.join(f.app, '.flutter_ota', 'packages', 'dynamic_modules'),
          'sneaky': p.join(f.app, '.flutter_ota', 'packages', 'sneaky'),
        },
      );

      final project = ProjectPackages.load(f.app);
      expect(project.toolOwned, ['dynamic_modules', 'sneaky']);
      expect(project.local.keys, isNot(anyOf(contains('dynamic_modules'), contains('sneaky'))));
      expect(project.outsideProject, isNot(anyOf(contains('dynamic_modules'), contains('sneaky'))));
      final g = FeatureGraph.build(project);
      expect(g.problems, isEmpty);
      expect(g.features.keys.toSet(), {'products', 'cart'});
      expect(g.roles.keys, isNot(anyOf(contains('dynamic_modules'), contains('sneaky'))));
      expect(g.reasons['dynamic_modules']!.single, contains('managed by flutter_ota'));
      expect(g.toJson()['tool_owned'], ['dynamic_modules', 'sneaky']);
      // The rest of the graph is unchanged.
      expect(g.roles['core'], PackageRole.shared);
      expect(g.roles['products_data'], PackageRole.featureInternal);
    });

    test('dynamic_modules is host-owned wherever it lives (for example in the toolchain)', () {
      expect(isToolOwnedPackage('dynamic_modules', '/somewhere/else/dynamic_modules', f.app), isTrue);
      expect(isToolOwnedPackage('core', p.join(f.app, 'packages', 'core'), f.app), isFalse);
      expect(isToolOwnedPackage('x', p.join(f.app, '.flutter_ota', 'packages', 'x'), f.app), isTrue);
    });
  });
}
