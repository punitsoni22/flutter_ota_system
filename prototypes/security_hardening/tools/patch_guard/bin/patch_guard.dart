// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 3 prototype: build-time security checks for a bytecode module, run BEFORE dart2bytecode.
// NOT the production patch generator.
//
//   dart --packages=<dart-src>/.dart_tool/package_config.json patch_guard.dart \
//     --root <dir with the module's packages> --package-config <module package_config.json> \
//     --module-packages a,b,c [--host-packages <host_packages.json|pubspec.lock>]
//     [--original-names a=x,b=y] [--sdk <dart-sdk>] [--json <report.json>]
//
// --module-packages: the packages DECLARED as compiled into the module (the module's own package,
// first = entry package, and the renamed copies from module.yaml change:/external:).
// --host-packages: the packages the host app provides (the baseline's host_packages.json, key
// "all", or the host's pubspec.lock). When given, EVERY package in the module's package config
// that is not a host package (flutter and sky_engine always count as host) is treated as module
// code and scanned, in addition to --module-packages. A non-host package the module reaches that
// is not in --module-packages is rejected (undeclared_dependency): it would be compiled into the
// module without being declared, pinned or policy-checked. Without --host-packages (legacy mode)
// everything outside --module-packages is assumed to resolve to the host.
//
// Checks (exit 4 = rejected, 0 = accepted, 2 = usage/analysis error):
//  0. Every module file must analyse without errors (analysis_error); compile errors are rejected.
//  1. Directive graph (imports, exports, parts, EVERY conditional-import/export configuration):
//     module code that reaches dart:ffi, dart:mirrors or another dart:_ library is rejected, with
//     the package chain. FFI reached only inside host packages is reported (runs AOT, not rejected).
//  2. Resolved AST of module code: references to dart:ffi elements (also through re-exports and
//     import prefixes), dynamic invocations (method, getter/setter, index, operators, calls of
//     values typed dynamic or Function), noSuchMethod overrides. Iterating or spreading a dynamic
//     value is NOT a dynamic call (the compiler inserts an implicit `as Iterable` cast).
//     Declarations that only USE the type `dynamic` are allowed.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:yaml/yaml.dart';

class Finding {
  Finding(this.rule, this.severity, this.package, this.file, this.line, this.message, [this.chain]);
  // ffi, mirrors, internal_library, dynamic_call, no_such_method, analysis_error,
  // undeclared_dependency, ffi_in_host
  final String rule;
  final String severity; // reject | warn
  final String package;
  final String file;
  final int line;
  final String message;
  final List<String>? chain;
  Map<String, Object?> toJson() =>
      {'rule': rule, 'severity': severity, 'package': package, 'file': file, 'line': line, 'message': message, if (chain != null) 'chain': chain};
}

late Map<String, Directory> packageRoots; // package name -> lib dir
late Set<String> modulePackages; // declared (--module-packages)
Set<String>? hostPackages; // null = legacy mode (everything not declared is host)
late Map<String, String> originalNames; // renamed -> original
final findings = <Finding>[];

String orig(String pkg) => originalNames[pkg] ?? pkg;

/// Packages provided by every Flutter host (SDK packages; the graph pass never walks them).
const sdkHostPackages = {'flutter', 'sky_engine'};

/// Whether code of [pkg] is compiled into the module (and so must be checked).
bool isModulePackage(String pkg) =>
    modulePackages.contains(pkg) ||
    (hostPackages != null && !hostPackages!.contains(pkg) && !sdkHostPackages.contains(pkg));

/// Reads the host package list: a baseline host_packages.json ({"all": [...]} or a JSON list) or
/// a pubspec.lock (the keys of `packages:`).
Set<String> readHostPackages(File f) {
  final text = f.readAsStringSync();
  if (f.path.endsWith('.json')) {
    final j = jsonDecode(text);
    final list = j is Map ? j['all'] : j;
    if (list is! List) throw FormatException('${f.path}: expected {"all": [...]} or a JSON list');
    return list.cast<String>().toSet();
  }
  final y = loadYaml(text);
  final pkgs = y is YamlMap ? y['packages'] : null;
  if (pkgs is! YamlMap) throw FormatException('${f.path}: expected a pubspec.lock with packages:');
  return pkgs.keys.cast<String>().toSet();
}

/// Resolves a directive URI to (package, file) or a dart: library name.
({String? pkg, File? file, String? dart}) resolve(String uri, File from, String fromPkg) {
  if (uri.startsWith('dart:')) return (pkg: null, file: null, dart: uri);
  if (uri.startsWith('package:')) {
    final rest = uri.substring(8);
    final slash = rest.indexOf('/');
    if (slash < 0) return (pkg: null, file: null, dart: null);
    final pkg = rest.substring(0, slash);
    final root = packageRoots[pkg];
    if (root == null) return (pkg: pkg, file: null, dart: null);
    return (pkg: pkg, file: File('${root.path}/${rest.substring(slash + 1)}'), dart: null);
  }
  return (pkg: fromPkg, file: File(from.parent.uri.resolve(uri).toFilePath()), dart: null);
}

/// Pass 1: directive graph over ALL configurations. BFS with parents for the chain.
List<(String, File)> graphPass(List<(String, File)> entries) {
  final reachableModule = <(String, File)>[];
  final parent = <String, String?>{};
  final pkgOf = <String, String>{};
  final queue = <(String, File)>[];
  for (final e in entries) {
    final k = e.$2.absolute.path;
    if (parent.containsKey(k)) continue;
    parent[k] = null;
    pkgOf[k] = e.$1;
    queue.add(e);
  }
  final hostFfiReported = <String>{};
  List<String> chainTo(String key, String last) {
    final pkgs = <String>[last];
    String? k = key;
    while (k != null) {
      final p = orig(pkgOf[k]!);
      if (pkgs.last != p) pkgs.add(p);
      k = parent[k];
    }
    return pkgs.reversed.toList();
  }

  while (queue.isNotEmpty) {
    final (pkg, file) = queue.removeAt(0);
    final key = file.absolute.path;
    if (!file.existsSync()) continue;
    final unit = parseString(content: file.readAsStringSync(), path: key, throwIfDiagnostics: false).unit;
    // Module code = a module package reached THROUGH module code. A non-host package reached
    // only through host libraries (e.g. a browser-only conditional import inside a host
    // package) is not compiled into the module: the host's libraries come from link.dill.
    final inModule = isModulePackage(pkg) && viaHost[key] != true;
    if (inModule) reachableModule.add((pkg, file));
    final uris = <(String, int, bool)>[];
    for (final d in unit.directives) {
      final line = unit.lineInfo.getLocation(d.offset).lineNumber;
      if (d is NamespaceDirective) {
        if (d.uri.stringValue != null) uris.add((d.uri.stringValue!, line, false));
        for (final c in d.configurations) {
          if (c.uri.stringValue != null) uris.add((c.uri.stringValue!, line, true));
        }
      } else if (d is PartDirective && d.uri.stringValue != null) {
        uris.add((d.uri.stringValue!, line, false));
      }
    }
    for (final (uri, line, conditional) in uris) {
      final r = resolve(uri, file, pkg);
      if (r.dart != null) {
        final lib = r.dart!;
        if (lib == 'dart:ffi') {
          if (inModule) {
            final via = conditionalVia[key] == true ? ' (reached through a conditional import)' : '';
            findings.add(Finding('ffi', 'reject', orig(pkg), key, line, 'module code imports dart:ffi$via', chainTo(key, 'dart:ffi')));
          } else if (hostFfiReported.add(pkg)) {
            findings.add(Finding('ffi_in_host', 'warn', orig(pkg), key, line,
                'host package uses dart:ffi; it runs AOT in the host (not compiled into the module)', chainTo(key, 'dart:ffi')));
          }
        } else if (inModule && lib == 'dart:mirrors') {
          findings.add(Finding('mirrors', 'reject', orig(pkg), key, line, 'dart:mirrors is not available', chainTo(key, lib)));
        } else if (inModule && lib.startsWith('dart:_')) {
          findings.add(Finding('internal_library', 'reject', orig(pkg), key, line, '$lib is an internal library', chainTo(key, lib)));
        }
        continue;
      }
      if (r.file == null) continue;
      final next = r.file!.absolute.path;
      // Only module code and the host libraries it reaches are walked; the Flutter SDK is host
      // code compiled AOT and is not walked (it contains desktop FFI back-ends).
      if (r.pkg == 'flutter' || r.pkg == 'sky_engine') continue;
      final nextViaHost = !inModule;
      // First visit, or a revisit that upgrades a host-only path to a module path.
      if (!parent.containsKey(next) || (viaHost[next] == true && !nextViaHost)) {
        conditionalVia[next] = conditional || conditionalVia[key] == true;
        parent[next] = key;
        pkgOf[next] = r.pkg!;
        viaHost[next] = nextViaHost;
        queue.add((r.pkg!, r.file!));
      }
    }
  }
  return reachableModule;
}

final conditionalVia = <String, bool>{};

/// True when a file was reached only through host libraries (see graphPass).
final viaHost = <String, bool>{};

/// Pass 2: resolved AST of module code.
class Checker extends RecursiveAstVisitor<void> {
  Checker(this.pkg, this.unit, this.path);
  final String pkg;
  final CompilationUnit unit;
  final String path;

  int line(AstNode n) => unit.lineInfo.getLocation(n.offset).lineNumber;
  void reject(String rule, AstNode n, String msg) => findings.add(Finding(rule, 'reject', orig(pkg), path, line(n), msg));

  static bool isDyn(DartType? t) => t is DynamicType;
  static bool objectMember(String name) =>
      const {'==', 'hashCode', 'runtimeType', 'toString', 'noSuchMethod'}.contains(name);

  void ffiElement(Element? e, AstNode n) {
    final lib = e?.library;
    if (lib != null && lib.uri.toString() == 'dart:ffi') {
      reject('ffi', n, 'uses dart:ffi element ${e!.displayName}');
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    ffiElement(node.element, node);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    ffiElement(node.element, node);
    super.visitNamedType(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    ffiElement(node.element, node);
    super.visitAnnotation(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final t = node.staticInvokeType;
    final target = node.realTarget;
    if (target != null && isDyn(target.staticType) && !objectMember(node.methodName.name)) {
      reject('dynamic_call', node, 'dynamic method invocation .${node.methodName.name}()');
    } else if (target == null && (t == null || isDyn(t) || (t.isDartCoreFunction))) {
      reject('dynamic_call', node, 'dynamic function invocation ${node.methodName.name}()');
    } else if (t != null && t.isDartCoreFunction) {
      reject('dynamic_call', node, 'call of a value typed Function');
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final ft = node.function.staticType;
    if (isDyn(ft) || (ft != null && ft.isDartCoreFunction)) {
      reject('dynamic_call', node, 'dynamic function invocation');
    }
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (isDyn(node.realTarget.staticType) && !objectMember(node.propertyName.name)) {
      reject('dynamic_call', node, 'dynamic member access .${node.propertyName.name}');
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.prefix.element is! PrefixElement && isDyn(node.prefix.staticType) && !objectMember(node.identifier.name)) {
      reject('dynamic_call', node, 'dynamic member access .${node.identifier.name}');
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    if (isDyn(node.realTarget.staticType)) reject('dynamic_call', node, 'dynamic index operator []');
    super.visitIndexExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final op = node.operator.lexeme;
    if (isDyn(node.leftOperand.staticType) && !const {'==', '!=', '&&', '||', '??'}.contains(op)) {
      reject('dynamic_call', node, 'dynamic operator $op');
    }
    super.visitBinaryExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (isDyn(node.operand.staticType) && node.operator.lexeme != '!') reject('dynamic_call', node, 'dynamic operator ${node.operator.lexeme}');
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (isDyn(node.operand.staticType) && node.operator.lexeme != '!') reject('dynamic_call', node, 'dynamic operator ${node.operator.lexeme}');
    super.visitPostfixExpression(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme == 'noSuchMethod') reject('no_such_method', node, 'noSuchMethod override (dynamic dispatch) is not supported');
    super.visitMethodDeclaration(node);
  }
}

/// The process exit code is the guard's verdict (a returned value from main is ignored by Dart).
Future<void> main(List<String> args) async {
  exitCode = await run(args);
}

Future<int> run(List<String> args) async {
  final a = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    a[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  if (!a.containsKey('root') || !a.containsKey('package-config') || !a.containsKey('module-packages')) {
    stderr.writeln('usage: patch_guard --root DIR --package-config FILE --module-packages a,b '
        '[--host-packages host_packages.json|pubspec.lock] [--original-names x=y] [--sdk DIR] [--json FILE]');
    return 2;
  }
  final cfgFile = File(a['package-config']!).absolute;
  final cfg = jsonDecode(cfgFile.readAsStringSync()) as Map<String, Object?>;
  packageRoots = {
    for (final p in (cfg['packages']! as List).cast<Map<String, Object?>>())
      p['name']! as String: Directory(cfgFile.uri
          .resolve((p['rootUri']! as String).endsWith('/') ? p['rootUri']! as String : '${p['rootUri']}/')
          .resolve(p['packageUri'] as String? ?? 'lib/')
          .toFilePath()
          .replaceFirst(RegExp(r'/+$'), '')),
  };
  modulePackages = a['module-packages']!.split(',').where((s) => s.isNotEmpty).toSet();
  if (a['host-packages'] != null) {
    try {
      hostPackages = readHostPackages(File(a['host-packages']!));
    } on Object catch (e) {
      stderr.writeln('patch_guard: cannot read host packages: $e');
      return 2;
    }
  }
  originalNames = {
    for (final kv in (a['original-names'] ?? '').split(',').where((s) => s.contains('=')))
      kv.split('=')[0]: kv.split('=')[1],
  };

  // Pass 1 starts from the entry package (the first of --module-packages): dart2bytecode compiles
  // only what the entry reaches, so that is exactly the code checked.
  for (final p in modulePackages) {
    if (packageRoots[p] == null || !packageRoots[p]!.existsSync()) {
      stderr.writeln('patch_guard: module package $p not in package config');
      return 2;
    }
  }
  final entryPkg = a['module-packages']!.split(',').first;
  final seeds = [
    for (final f in packageRoots[entryPkg]!.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
      (entryPkg, f),
  ];
  final entries = graphPass(seeds);

  // Gap 2: a non-host package that the module reaches but that is not declared is compiled into
  // the module unpinned and without the pkg_rename policy check. It is scanned (above) AND refused.
  final reachedPackages = {for (final (p, _) in entries) p};
  for (final p in reachedPackages.where((p) => !modulePackages.contains(p)).toList()..sort()) {
    final first = entries.firstWhere((e) => e.$1 == p).$2.absolute.path;
    findings.add(Finding('undeclared_dependency', 'reject', orig(p), first, 1,
        'package $p is compiled into the module but is neither a host package nor declared in module.yaml '
        '(change: or external:)'));
  }

  // Pass 2: resolved AST of module-compiled files.
  final collection = AnalysisContextCollectionImpl(
    includedPaths: [for (final p in {...modulePackages, ...reachedPackages}) packageRoots[p]!.absolute.path],
    packageConfigFile: cfgFile.path,
    sdkPath: a['sdk'],
  );
  var resolveErrors = 0;
  for (final (pkg, file) in entries) {
    final path = file.absolute.path;
    final ctx = collection.contextFor(path);
    final r = await ctx.currentSession.getResolvedUnit(path);
    if (r is! ResolvedUnitResult) {
      resolveErrors++;
      findings.add(Finding('analysis_error', 'reject', orig(pkg), path, 0, 'file could not be resolved (${r.runtimeType})'));
      continue;
    }
    if (r.isPart && r.unit.directives.whereType<PartOfDirective>().isEmpty) continue;
    // Gap 1: compare the enum (its name is lowercase 'error'; the old 'ERROR' check never fired).
    final errors = r.diagnostics.where((d) => d.severity == Severity.error).toList();
    if (errors.isNotEmpty) {
      resolveErrors++;
      for (final e in errors) {
        findings.add(Finding('analysis_error', 'reject', orig(pkg), path, r.lineInfo.getLocation(e.offset).lineNumber,
            'compile error: ${e.message}'));
      }
    }
    r.unit.accept(Checker(pkg, r.unit, path));
  }
  await collection.dispose();

  final rejects = findings.where((f) => f.severity == 'reject').toList();
  final report = {
    'accepted': rejects.isEmpty && resolveErrors == 0,
    'analysis_errors': resolveErrors,
    'findings': findings.map((f) => f.toJson()).toList(),
  };
  if (a['json'] != null) File(a['json']!).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  for (final f in findings.where((f) => f.severity == 'warn')) {
    stderr.writeln('WARNING ${f.rule}: ${f.message} (${f.package})${f.chain == null ? '' : '\n  Reached through: ${f.chain!.join(' -> ')}'}');
  }
  if (rejects.isEmpty && resolveErrors == 0) {
    print('patch_guard: accepted (${entries.length} files in ${reachedPackages.length} module packages)');
    return 0;
  }
  final byRule = <String, List<Finding>>{};
  for (final f in rejects) {
    (byRule[f.rule] ??= []).add(f);
  }
  final out = StringBuffer('PATCH REJECTED\n');
  for (final MapEntry(key: rule, value: list) in byRule.entries) {
    final f = list.first;
    final reason = switch (rule) {
      'ffi' => 'Unsupported FFI dependency detected.',
      'mirrors' => 'dart:mirrors is not supported.',
      'internal_library' => 'Internal Dart library imported.',
      'dynamic_call' => 'Dynamic invocation detected (dynamic calls are disabled in modules).',
      'no_such_method' => 'noSuchMethod override detected.',
      'analysis_error' => 'The module sources do not analyse cleanly ($resolveErrors file(s) with compile errors).',
      'undeclared_dependency' => 'Undeclared dependency compiled into the module (declare it under external: '
          'in module.yaml so it is pinned and policy-checked, or ship it in the host).',
      _ => rule,
    };
    out.writeln('\nReason: $reason\n\nPackage: ${f.package}');
    if (f.chain != null) out.writeln('Imported through: ${f.chain!.join(' -> ')}');
    for (final x in list.take(5)) {
      out.writeln('  ${x.file.split('/').skip(x.file.split('/').length - 3).join('/')}:${x.line}  ${x.message}');
    }
    if (list.length > 5) out.writeln('  … ${list.length - 5} more');
  }
  if (byRule.keys.any((r) => r == 'ffi' || r == 'mirrors' || r == 'internal_library')) {
    out.writeln('\nThis dependency requires a full application release.');
  } else if (byRule.containsKey('dynamic_call') || byRule.containsKey('no_such_method')) {
    out.writeln('\nRewrite this code with static types: dynamic dispatch is not supported in patches.');
  } else if (byRule.containsKey('analysis_error')) {
    out.writeln('\nFix the compile errors (and re-run code generation if generated files are stale).');
  }
  stderr.write(out);
  return 4;
}
