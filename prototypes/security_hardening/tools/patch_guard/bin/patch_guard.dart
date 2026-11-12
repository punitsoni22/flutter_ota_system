// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 3 prototype: build-time security checks for a bytecode module, run BEFORE dart2bytecode.
// NOT the production patch generator.
//
//   dart --packages=<dart-src>/.dart_tool/package_config.json patch_guard.dart \
//     --root <dir with the module's packages> --package-config <module package_config.json> \
//     --module-packages a,b,c [--original-names a=x,b=y] [--sdk <dart-sdk>] [--json <report.json>]
//
// --module-packages: the packages that are COMPILED INTO the module (the module's own package and
// the renamed copies). Everything else resolves to the host and runs AOT.
//
// Checks (exit 4 = rejected, 0 = accepted, 2 = usage/analysis error):
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
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';

class Finding {
  Finding(this.rule, this.severity, this.package, this.file, this.line, this.message, [this.chain]);
  final String rule; // ffi, mirrors, internal_library, dynamic_call, no_such_method, ffi_in_host
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
late Set<String> modulePackages;
late Map<String, String> originalNames; // renamed -> original
final findings = <Finding>[];

String orig(String pkg) => originalNames[pkg] ?? pkg;

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
    final inModule = modulePackages.contains(pkg);
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
      if (!parent.containsKey(next)) {
        conditionalVia[next] = conditional || conditionalVia[key] == true;
        parent[next] = key;
        pkgOf[next] = r.pkg!;
        queue.add((r.pkg!, r.file!));
      }
    }
  }
  return reachableModule;
}

final conditionalVia = <String, bool>{};

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
    stderr.writeln('usage: patch_guard --root DIR --package-config FILE --module-packages a,b [--original-names x=y] [--sdk DIR] [--json FILE]');
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

  // Pass 2: resolved AST of module-compiled files.
  final collection = AnalysisContextCollectionImpl(
    includedPaths: [for (final p in modulePackages) packageRoots[p]!.absolute.path],
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
      continue;
    }
    if (r.isPart && r.unit.directives.whereType<PartOfDirective>().isEmpty) continue;
    final errors = r.diagnostics.where((d) => d.severity.name == 'ERROR').toList();
    if (errors.isNotEmpty) {
      resolveErrors++;
      for (final e in errors.take(3)) {
        stderr.writeln('patch_guard: analysis error in $path: ${e.message}');
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
  if (resolveErrors > 0) {
    stderr.writeln('PATCH REJECTED\n\nReason: the module sources do not analyse cleanly ($resolveErrors file(s)).');
    return 4;
  }
  if (rejects.isEmpty) {
    print('patch_guard: accepted (${entries.length} files in ${modulePackages.length} module packages)');
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
      _ => rule,
    };
    out.writeln('\nReason: $reason\n\nPackage: ${f.package}');
    if (f.chain != null) out.writeln('Imported through: ${f.chain!.join(' -> ')}');
    for (final x in list.take(5)) {
      out.writeln('  ${x.file.split('/').skip(x.file.split('/').length - 3).join('/')}:${x.line}  ${x.message}');
    }
    if (list.length > 5) out.writeln('  … ${list.length - 5} more');
  }
  out.writeln(byRule.keys.any((r) => r == 'ffi' || r == 'mirrors' || r == 'internal_library')
      ? '\nThis dependency requires a full application release.'
      : '\nRewrite this code with static types: dynamic dispatch is not supported in patches.');
  stderr.write(out);
  return 4;
}
