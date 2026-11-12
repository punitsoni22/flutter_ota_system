// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Automatic feature discovery (milestone 4F, owner decision D1).
//
// Conventions (no config files):
//  * Local packages are the path dependencies (and workspace members) whose sources are inside
//    the project directory.
//  * A local package is a FEATURE when its main library `lib/<package>.dart` declares (or
//    exports) a public, non-abstract class named `<PascalCase(package)>Feature`, for example
//    `ProductsFeature` in `packages/products/lib/products.dart`. That class is the feature's
//    entry: the generated registry creates it with an unnamed constructor that takes no
//    required arguments.
//  * The entry class must extend or implement a CONTRACT type from a host-owned package (a
//    shared local package such as `packages/core`, a hosted package, or the SDK). The registry
//    exposes the feature with that contract type, because a patch can only replace an object
//    whose type the store build owns.
//  * Every other local package is either FEATURE-INTERNAL (used by exactly one feature, and by
//    nothing else) and patched together with it, or SHARED (host-owned): used by the app's own
//    code, by another shared package, by two or more features, or by no feature at all.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/app_project.dart' show otaWorkDirName;
import 'dart_source.dart';
import 'package_graph.dart';

/// File name of the generated registry inside the app's `lib/`.
const registryFileName = 'flutter_ota_features.g.dart';

/// Import of the SDK used by the generated registry.
const sdkPackageName = 'flutter_ota_system';
const sdkLibraryUri = 'package:flutter_ota_system/flutter_ota_system.dart';

enum PackageRole {
  /// The app package itself: compiled AOT into the store build, never patchable.
  app,

  /// A feature package with an entry class: patchable through its generated slot.
  feature,

  /// A package used only by one feature: patched together with that feature.
  featureInternal,

  /// A host-owned package (contracts, shared models, shared state): needs a store release.
  shared,
}

String roleLabel(PackageRole r) => switch (r) {
  PackageRole.app => 'app',
  PackageRole.feature => 'feature',
  PackageRole.featureInternal => 'feature-internal',
  PackageRole.shared => 'shared (host-owned)',
};

/// A supertype of a feature's entry class and where it is declared.
class ContractCandidate {
  ContractCandidate(this.type, this.package, this.libraryUri);
  final String type;
  final String package;

  /// Library to import for [type] (the URI the feature itself uses).
  final String libraryUri;
}

/// The entry class of a feature package and the contract type the registry exposes.
class FeatureEntry {
  FeatureEntry({
    required this.package,
    required this.className,
    required this.libraryUri,
    required this.declaredIn,
    required this.candidates,
  });

  final String package;
  final String className;

  /// `package:<package>/<package>.dart`
  final String libraryUri;

  /// File (relative to the package) that declares the class.
  final String declaredIn;

  /// Supertypes declared outside the feature package, nearest first.
  final List<ContractCandidate> candidates;

  /// The chosen host-owned contract (set by classification; null = none found).
  ContractCandidate? contract;

  String get contractType => contract?.type ?? '?';
  String get contractPackage => contract?.package ?? '?';
  String get contractLibraryUri => contract?.libraryUri ?? '?';

  /// Slot name: the package name. It never changes, so patches find their slot.
  String get slot => package;

  /// Getter name in `OtaFeatures`.
  String get getter {
    final c = camelCase(package);
    return reservedWords.contains(c) ? '${c}Feature' : c;
  }

  Map<String, Object?> toJson() => {
    'package': package,
    'slot': slot,
    'getter': getter,
    'class': className,
    'library': libraryUri,
    'declared_in': declaredIn,
    'contract': {'type': contractType, 'package': contractPackage, 'library': contractLibraryUri},
  };
}

/// The classified package graph of a project.
class FeatureGraph {
  FeatureGraph._(this.project);

  final ProjectPackages project;
  final roles = <String, PackageRole>{};
  final reasons = <String, List<String>>{};
  final features = <String, FeatureEntry>{};

  /// feature-internal package -> the feature that owns it.
  final internalOwner = <String, String>{};

  /// Blocking problems (generation and patching refuse while any exist).
  final problems = <String>[];
  final warnings = <String>[];

  /// package -> first app file that imports it directly (outside the generated registry).
  final appImports = <String, String>{};

  String get appName => project.app.name;

  Iterable<String> packagesWithRole(PackageRole r) =>
      (roles.entries.where((e) => e.value == r).map((e) => e.key).toList()..sort());

  /// Local packages a feature compiles together with it (itself and its internal packages).
  List<String> unitOf(String feature) => [
    feature,
    ...(internalOwner.entries.where((e) => e.value == feature).map((e) => e.key).toList()..sort()),
  ];

  /// Local packages (not the app) that [name] depends on directly.
  Set<String> localDepsOf(String name) {
    final pkg = name == appName ? project.app : project.local[name];
    if (pkg == null) return {};
    return pkg.dependencies.where(project.local.containsKey).toSet();
  }

  /// Local packages that depend on [name] directly.
  Set<String> localDependentsOf(String name) =>
      project.local.values.where((l) => l.dependencies.contains(name)).map((l) => l.name).toSet();

  Map<String, Object?> toJson() => {
    'app': appName,
    'packages': {
      for (final name in [appName, ...(project.local.keys.toList()..sort())])
        name: {
          'role': roles[name]!.name,
          'dir': name == appName ? '.' : project.local[name]!.relativeDir,
          'depends_on': (localDepsOf(name).toList()..sort()),
          'used_by': ([if (project.app.dependencies.contains(name)) appName, ...localDependentsOf(name)]..sort()),
          if (internalOwner[name] != null) 'feature': internalOwner[name],
          'reasons': reasons[name] ?? const <String>[],
        },
    },
    'features': {for (final f in (features.keys.toList()..sort())) f: features[f]!.toJson()},
    'outside_project': project.outsideProject,
    'tool_owned': project.toolOwned,
    'problems': problems,
    'warnings': warnings,
  };

  /// Discovers and classifies the packages of [project].
  static FeatureGraph build(ProjectPackages project) {
    final g = FeatureGraph._(project);
    g._classify();
    return g;
  }

  void _reason(String pkg, String why) => (reasons[pkg] ??= []).add(why);

  void _classify() {
    final app = project.app;
    roles[app.name] = PackageRole.app;
    _reason(app.name, 'the app package is compiled into the store build (AOT); a change needs a new store release');

    // 1. Entry classes.
    final candidates = <String, FeatureEntry>{};
    final entryProblems = <String, List<String>>{};
    for (final pkg in project.local.values) {
      final (entry, problems) = findFeatureEntry(pkg, project.config);
      if (entry != null) candidates[pkg.name] = entry;
      if (problems.isNotEmpty) entryProblems[pkg.name] = problems;
    }

    // 2. What the app's own code imports (outside the generated registry).
    final lib = Directory(app.libDir);
    if (lib.existsSync()) {
      final files = lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final rel = p.relative(f.path, from: app.dir);
        if (p.basename(f.path) == registryFileName) continue;
        for (final d in parseDirectives(f.readAsStringSync())) {
          final name = d.packageName;
          if (name != null && project.local.containsKey(name)) appImports.putIfAbsent(name, () => rel);
        }
      }
    }

    // 3. Roles, until nothing changes (a shared package pins the features it uses).
    final shared = <String>{};
    final feats = {...candidates.keys};
    for (final name in project.outsideProject) {
      _reason(name, 'path dependency outside the project directory: treated as host-owned');
    }
    for (final name in project.toolOwned) {
      _reason(name, 'managed by flutter_ota ($otaWorkDirName/ or the module loader): host-owned, never patched');
    }
    var changed = true;
    final why = <String, String>{};
    while (changed) {
      changed = false;
      for (final f in feats.toList()) {
        String? pin;
        if (appImports.containsKey(f)) {
          pin =
              'imported directly by the app (${appImports[f]}); use OtaFeatures.${candidates[f]!.getter} '
              'instead, so the feature is reached only through its slot';
        } else {
          final sharedUser = project.local.values
              .where((l) => shared.contains(l.name) && l.dependencies.contains(f))
              .map((l) => l.name)
              .toList();
          if (sharedUser.isNotEmpty) pin = 'used by the shared package ${sharedUser.first}';
        }
        if (pin != null) {
          feats.remove(f);
          shared.add(f);
          why[f] = pin;
          warnings.add('$f has a feature entry but is $pin, so it is treated as shared (not patchable).');
          changed = true;
        }
      }
      for (final pkg in project.local.values) {
        final n = pkg.name;
        if (feats.contains(n) || shared.contains(n)) continue;
        final dependents = project.dependentsOf(n);
        String? reason;
        if (dependents.contains(app.name)) {
          reason = 'used directly by the app';
        } else if (appImports.containsKey(n)) {
          reason = 'imported by the app (${appImports[n]})';
        } else if (dependents.any(shared.contains)) {
          reason = 'used by the shared package ${dependents.firstWhere(shared.contains)}';
        } else {
          final owners = _owningFeatures(n, feats, shared, {});
          if (owners.length >= 2) {
            reason = 'used by ${owners.length} features (${(owners.toList()..sort()).join(', ')})';
          } else if (owners.isEmpty) {
            reason = 'not used by any feature';
          }
        }
        if (reason != null) {
          shared.add(n);
          why[n] = reason;
          changed = true;
        }
      }
    }
    for (final f in feats) {
      roles[f] = PackageRole.feature;
      features[f] = candidates[f]!;
      _reason(f, 'feature entry ${candidates[f]!.className} in ${candidates[f]!.declaredIn}');
    }
    for (final pkg in project.local.values) {
      final n = pkg.name;
      if (roles.containsKey(n)) continue;
      if (shared.contains(n)) {
        roles[n] = PackageRole.shared;
        _reason(n, why[n] ?? 'host-owned');
        continue;
      }
      final owners = _owningFeatures(n, feats, shared, {});
      roles[n] = PackageRole.featureInternal;
      internalOwner[n] = owners.single;
      _reason(n, 'used only by the feature ${owners.single}; patched together with it');
    }

    // 4. Checks of each feature. The contract is the nearest supertype owned by the store build:
    // from the SDK, a hosted package, a package outside the project or a shared local package.
    for (final e in features.values.toList()) {
      bool hostOwned(ContractCandidate c) {
        if (c.package == e.package || c.package == app.name) return false;
        final role = roles[c.package];
        return role == null || role == PackageRole.shared;
      }

      e.contract = e.candidates.where(hostOwned).firstOrNull;
      if (e.contract == null) {
        final seen = e.candidates.map(
          (c) =>
              '${c.type} (${c.package == app.name ? 'app' : roleLabel(roles[c.package] ?? PackageRole.shared)} package ${c.package})',
        );
        problems.add(
          '${e.package}: ${e.className} has no host-owned supertype, so the store build cannot call a patched '
          'copy of it. Make it extend OtaFeature from $sdkPackageName (`class ${e.className} extends OtaFeature`), '
          'or implement an abstract class from a shared package such as packages/core.'
          '${seen.isEmpty ? '' : ' Found only: ${seen.join(', ')}.'}',
        );
      }
      if (!app.dependencies.contains(e.package)) {
        problems.add(
          '${e.package} is a feature, but the app does not depend on it directly. Add it to '
          'dependencies: in pubspec.yaml (for example `${e.package}: {path: ${project.local[e.package]!.relativeDir}}`).',
        );
      }
      final pkg = project.local[e.package]!;
      if (pkg.isPlugin || pkg.nativeDirs.isNotEmpty) {
        warnings.add(
          '${e.package} contains native code (${[if (pkg.isPlugin) 'flutter.plugin', ...pkg.nativeDirs].join(', ')}): '
          'only its Dart code can be patched; native changes need a new store release.',
        );
      }
    }
    entryProblems.forEach((pkg, list) {
      for (final pr in list) {
        problems.add('$pkg: $pr');
      }
    });
    if (features.isNotEmpty && !app.dependencies.contains(sdkPackageName)) {
      warnings.add('The app does not depend on $sdkPackageName; the generated registry needs it.');
    }
    final registry = File(p.join(app.libDir, registryFileName));
    if (features.isNotEmpty && registry.existsSync()) {
      final used = Directory(app.libDir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') && p.basename(f.path) != registryFileName)
          .any((f) => parseDirectives(f.readAsStringSync()).any((d) => d.uri.endsWith(registryFileName)));
      if (!used) {
        warnings.add('lib/$registryFileName is not imported by the app yet; call OtaFeatures.<name> to use the slots.');
      }
    }
  }

  /// Features that (transitively, through non-feature, non-shared packages) depend on [n].
  Set<String> _owningFeatures(String n, Set<String> feats, Set<String> shared, Set<String> seen) {
    if (!seen.add(n)) return {};
    final out = <String>{};
    for (final d in localDependentsOf(n)) {
      if (feats.contains(d)) {
        out.add(d);
      } else if (shared.contains(d)) {
        continue;
      } else {
        out.addAll(_owningFeatures(d, feats, shared, seen));
      }
    }
    return out;
  }
}

/// Accepted entry class names for a package.
List<String> entryClassNames(String package) => {
  '${pascalCase(package)}Feature',
  if (package.startsWith('feature_') && package.length > 8) '${pascalCase(package.substring(8))}Feature',
  if (package.endsWith('_feature')) pascalCase(package),
}.toList();

class _LibFile {
  _LibFile(this.path, this.libraryPath);
  final String path;

  /// For a part file, the library file that owns its imports.
  final String libraryPath;
}

/// Finds the entry class of [pkg] (see the conventions at the top of this file). Returns
/// (null, []) when the package is not a feature.
(FeatureEntry?, List<String>) findFeatureEntry(LocalPackage pkg, PackageConfig config) {
  final main = File(p.join(pkg.libDir, '${pkg.name}.dart'));
  if (!main.existsSync()) return (null, const []);
  final names = entryClassNames(pkg.name);
  final files = _libraryFiles(main.path, pkg.libDir, pkg.name);
  TypeDeclaration? decl;
  _LibFile? where;
  for (final f in files) {
    for (final t in findTypeDeclarations(File(f.path).readAsStringSync())) {
      if (t.keyword == 'class' && names.contains(t.name)) {
        decl = t;
        where = f;
        break;
      }
    }
    if (decl != null) break;
  }
  if (decl == null || where == null) return (null, const []);
  final problems = <String>[];
  final rel = p.relative(where.path, from: pkg.dir);
  if (decl.isAbstract) problems.add('${decl.name} ($rel) must not be abstract: the registry creates it.');
  if (decl.header.trimLeft().startsWith('<')) problems.add('${decl.name} ($rel) must not have type parameters.');
  final ctors = decl.unnamedConstructorParameters;
  final named = RegExp('\\b${RegExp.escape(decl.name)}\\.[A-Za-z_\$][A-Za-z0-9_\$]*\\s*\\(').hasMatch(decl.body);
  if ((ctors.isEmpty && named) || (ctors.isNotEmpty && ctors.every(hasRequiredParameter))) {
    problems.add(
      '${decl.name} ($rel) needs an unnamed constructor without required arguments, '
      'for example `const ${decl.name}();`.',
    );
  }
  final candidates = <ContractCandidate>[];
  final seenTypes = <String>{};
  // Breadth-first: direct supertypes first; supertypes declared in the feature package itself are
  // expanded (for example `ProductsFeature extends _Base` with `_Base extends OtaFeature`).
  var level = <(String, _LibFile)>[
    for (final t in [?decl.superclass, ...decl.interfaces]) (t, where),
  ];
  for (var depth = 0; depth < 8 && level.isNotEmpty; depth++) {
    final next = <(String, _LibFile)>[];
    for (final (typeRef, from) in level) {
      if (typeRef == 'Object' || !seenTypes.add('${from.libraryPath}|$typeRef')) continue;
      final found = _resolveType(typeRef, from, pkg, config);
      if (found == null) continue;
      final (owner, uri) = found;
      final simple = typeRef.contains('.') ? typeRef.substring(typeRef.indexOf('.') + 1) : typeRef;
      if (owner != pkg.name) {
        candidates.add(ContractCandidate(simple, owner, uri));
        continue;
      }
      if (!uri.startsWith('package:${pkg.name}/')) continue;
      for (final f in _libraryFiles(
        p.join(pkg.libDir, uri.substring('package:${pkg.name}/'.length)),
        pkg.libDir,
        pkg.name,
      )) {
        final t = findTypeDeclarations(File(f.path).readAsStringSync()).where((t) => t.name == simple).firstOrNull;
        if (t != null) {
          next.addAll([
            for (final s in [?t.superclass, ...t.interfaces]) (s, f),
          ]);
          break;
        }
      }
    }
    level = next;
  }
  return (
    FeatureEntry(
      package: pkg.name,
      className: decl.name,
      libraryUri: 'package:${pkg.name}/${pkg.name}.dart',
      declaredIn: rel,
      candidates: candidates,
    ),
    problems,
  );
}

/// The files of the library [mainPath] plus the files it exports or includes as parts, inside
/// the same package.
List<_LibFile> _libraryFiles(String mainPath, String libDir, String own) {
  final out = <_LibFile>[];
  final seen = <String>{};
  void visit(String path, String libraryPath, int depth) {
    final norm = p.normalize(path);
    if (depth > 16 || !seen.add(norm) || !File(norm).existsSync()) return;
    out.add(_LibFile(norm, libraryPath));
    for (final d in parseDirectives(File(norm).readAsStringSync())) {
      final target = _localTarget(d.uri, norm, libDir, own);
      if (target == null) continue;
      if (d.kind == 'part') visit(target, libraryPath, depth + 1);
      if (d.kind == 'export') visit(target, target, depth + 1);
    }
  }

  visit(mainPath, mainPath, 0);
  return out;
}

/// Resolves a relative URI or a `package:<own>/` URI of the package in [libDir].
String? _localTarget(String uri, String fromFile, String libDir, String own) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    // Only files of the same package are followed.
    final rest = uri.substring(8);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final name = rest.substring(0, slash);
    if (name != own) return null;
    return p.join(libDir, rest.substring(slash + 1));
  }
  if (uri.contains(':')) return null;
  return p.join(p.dirname(fromFile), uri);
}

/// Finds which package declares [typeRef] as seen from [from]. Returns (package, library URI to
/// import) or null.
(String, String)? _resolveType(String typeRef, _LibFile from, LocalPackage pkg, PackageConfig config) {
  final dot = typeRef.indexOf('.');
  final prefix = dot < 0 ? null : typeRef.substring(0, dot);
  final name = dot < 0 ? typeRef : typeRef.substring(dot + 1);
  final directives = parseDirectives(File(from.libraryPath).readAsStringSync());
  if (prefix == null) {
    // Declared in the feature library itself?
    for (final f in _libraryFiles(from.libraryPath, pkg.libDir, pkg.name)) {
      if (findTypeDeclarations(File(f.path).readAsStringSync()).any((t) => t.name == name)) {
        return (pkg.name, 'package:${pkg.name}/${p.relative(from.libraryPath, from: pkg.libDir)}');
      }
    }
  }
  for (final d in directives) {
    if (d.kind != 'import' || d.prefix != prefix || !d.exposes(name)) continue;
    String? targetPkg;
    String? path;
    if (d.uri.startsWith('package:')) {
      targetPkg = d.packageName;
      path = d.packagePath;
    } else if (!d.uri.contains(':')) {
      targetPkg = pkg.name;
      path = p.relative(p.normalize(p.join(p.dirname(from.libraryPath), d.uri)), from: pkg.libDir);
    }
    if (targetPkg == null || path == null) continue;
    final entry = config.packages[targetPkg];
    final libDir = targetPkg == pkg.name ? pkg.libDir : entry?.libDir;
    if (libDir == null) continue;
    final owner = _declares(p.join(libDir, path), libDir, targetPkg, name, {}, 0, config);
    if (owner != null) return (owner, targetPkg == pkg.name ? 'package:${pkg.name}/$path' : d.uri);
  }
  return null;
}

/// The package that declares the type [name] reached from the library at [path] (following
/// parts and exports, also into other packages), or null.
String? _declares(
  String path,
  String libDir,
  String own,
  String name,
  Set<String> seen,
  int depth,
  PackageConfig config,
) {
  final norm = p.normalize(path);
  if (depth > 16 || !seen.add(norm)) return null;
  final f = File(norm);
  if (!f.existsSync()) return null;
  final src = f.readAsStringSync();
  if (findTypeDeclarations(src).any((t) => t.name == name)) return own;
  for (final d in parseDirectives(src)) {
    if (d.kind == 'part' && !d.uri.contains(':')) {
      final r = _declares(p.join(p.dirname(norm), d.uri), libDir, own, name, seen, depth + 1, config);
      if (r != null) return r;
    }
    if (d.kind == 'export' && d.exposes(name)) {
      String? r;
      if (!d.uri.contains(':')) {
        r = _declares(p.join(p.dirname(norm), d.uri), libDir, own, name, seen, depth + 1, config);
      } else if (d.uri.startsWith('package:')) {
        final other = d.packageName!;
        final otherLib = other == own ? libDir : config.packages[other]?.libDir;
        if (otherLib != null) {
          r = _declares(p.join(otherLib, d.packagePath!), otherLib, other, name, seen, depth + 1, config);
        }
      }
      if (r != null) return r;
    }
  }
  return null;
}
