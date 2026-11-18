// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Reads a Dart package (resolved by the analyzer) and indexes what the redirect tool needs:
// executables (functions, methods, getters, setters, operators), containers (classes,
// mixins, enums, extensions) with their fields/constructors/headers, and top-level
// variables.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String hash10(String s) => sha1.convert(s.codeUnits).toString().substring(0, 10);

class Unit {
  Unit(this.pkg, this.rel, this.result);

  final String pkg;
  final String rel; // path below lib/, with forward slashes
  final ResolvedUnitResult result;

  CompilationUnit get ast => result.unit;
  String get src => result.content;
  String get uri => 'package:$pkg/$rel';
}

/// A class, mixin, enum or extension.
class Box {
  Box(this.unit, this.node, this.kind, this.name, this.typeParams, this.members, this.element);

  final Unit unit;
  final CompilationUnitMember node;
  final String kind; // class | mixin | enum | extension
  final String name; // extensions without a name: 'ext:<on type>'
  final TypeParameterList? typeParams;
  final List<ClassMember> members;
  final InstanceElement? element;

  String get tpNames => typeParams == null
      ? ''
      : '<${typeParams!.typeParameters.map((t) => t.name.lexeme).join(', ')}>';

  String get tpDecl => typeParams?.toSource() ?? '';

  bool get isPrivate => name.startsWith('_');

  /// The token of the declared name (class, enum or mixin), used when copying the class.
  Token? get nameToken => switch (node) {
        ClassDeclaration n => n.namePart.typeName,
        EnumDeclaration n => n.namePart.typeName,
        MixinDeclaration n => n.name,
        _ => null,
      };

  bool get hasConstCtor => ctors.any((c) => c.constKeyword != null);

  /// Header without annotations and body: modifiers, name, type parameters, clauses.
  String get header {
    final start = (node as AnnotatedNode).firstTokenAfterCommentAndMetadata.offset;
    final body = switch (node) {
      ClassDeclaration n => n.body.offset,
      MixinDeclaration n => n.body.offset,
      EnumDeclaration n => n.body.offset,
      ExtensionDeclaration n => n.body.offset,
      _ => node.end,
    };
    return norm(unit.src.substring(start, body));
  }

  List<String> get enumConstants => node is EnumDeclaration
      ? (node as EnumDeclaration).body.constants.map((c) => norm(c.toSource())).toList()
      : const [];

  Iterable<FieldDeclaration> get fields => members.whereType<FieldDeclaration>();
  Iterable<ConstructorDeclaration> get ctors => members.whereType<ConstructorDeclaration>();

  /// Widget-like classes can ship as a fresh copy (tier 3w).
  bool get isWidgetLike {
    if (node is! ClassDeclaration) return false;
    final ext = (node as ClassDeclaration).extendsClause?.superclass.name.lexeme;
    return const {
      'Widget', 'StatelessWidget', 'StatefulWidget', 'State', 'HookWidget',
      'ConsumerWidget', 'ConsumerStatefulWidget', 'ConsumerState', 'HookConsumerWidget',
    }.contains(ext);
  }
}

/// A function body the tool can redirect.
class Exe {
  Exe(this.unit, this.box, this.node);

  final Unit unit;
  final Box? box;
  final AstNode node; // MethodDeclaration | FunctionDeclaration

  MethodDeclaration? get m => node is MethodDeclaration ? node as MethodDeclaration : null;
  FunctionDeclaration? get f => node is FunctionDeclaration ? node as FunctionDeclaration : null;

  String get name => m?.name.lexeme ?? f!.name.lexeme;
  String get kind {
    if (m != null) {
      if (m!.isGetter) return 'getter';
      if (m!.isSetter) return 'setter';
      if (m!.isOperator) return 'operator';
      return 'method';
    }
    if (f!.isGetter) return 'getter';
    if (f!.isSetter) return 'setter';
    return 'function';
  }

  bool get isInstance => m != null && !m!.isStatic;
  FunctionBody get body => m != null ? m!.body : f!.functionExpression.body;
  FormalParameterList? get params =>
      m != null ? m!.parameters : f!.functionExpression.parameters;
  TypeParameterList? get typeParams =>
      m != null ? m!.typeParameters : f!.functionExpression.typeParameters;
  TypeAnnotation? get returnType => m != null ? m!.returnType : f!.returnType;
  bool get isExternal => (m != null ? m!.externalKeyword : f!.externalKeyword) != null;
  bool get isAbstract => body is EmptyFunctionBody;
  bool get isOverride => (node as AnnotatedNode)
      .metadata
      .any((a) => a.name.name == 'override');
  bool get redirectable =>
      !isExternal && (body is BlockFunctionBody || body is ExpressionFunctionBody);

  /// A tiny leaf: a one-expression body that only reads fields/variables and does arithmetic or
  /// comparisons (no calls, no allocation, no strings, no await). Such functions are what the
  /// optimizer inlines into hot loops, so a redirect check there costs the most.
  bool get isTinyLeaf {
    final b = body;
    final Expression expr;
    if (b is ExpressionFunctionBody) {
      expr = b.expression;
    } else if (b is BlockFunctionBody &&
        b.block.statements.length == 1 &&
        b.block.statements.first is ReturnStatement &&
        (b.block.statements.first as ReturnStatement).expression != null) {
      expr = (b.block.statements.first as ReturnStatement).expression!;
    } else {
      return false;
    }
    if (b.isAsynchronous || b.isGenerator) return false;
    var ok = true;
    void check(AstNode n) {
      if (!ok) return;
      final allowed = n is SimpleIdentifier ||
          n is PrefixedIdentifier ||
          n is PropertyAccess ||
          n is ThisExpression ||
          n is IntegerLiteral ||
          n is DoubleLiteral ||
          n is BooleanLiteral ||
          n is NullLiteral ||
          n is ParenthesizedExpression ||
          n is ConditionalExpression ||
          n is PrefixExpression ||
          (n is BinaryExpression && _builtinOperator(n.element)) ||
          n is AsExpression ||
          n is IsExpression ||
          n is NamedType;
      if (!allowed) {
        ok = false;
        return;
      }
      n.childEntities.whereType<AstNode>().forEach(check);
    }

    check(expr);
    return ok;
  }

  /// Operators of num/int/double/bool (or `==`, `&&`, `||`, `??`, which have no element).
  static bool _builtinOperator(Element? e) {
    if (e == null) return true;
    final owner = e.enclosingElement?.name;
    return e.library?.uri.toString() == 'dart:core' &&
        const {'num', 'int', 'double', 'bool', 'Object'}.contains(owner);
  }

  String get key => '${unit.rel}::${box?.name ?? ''}::$name::$kind';
  String get slot => 'ota\$s${hash10(key)}';
  String get replacement => 'ota\$r${hash10(key)}';

  /// Signature without annotations: modifiers, return type, name, type parameters,
  /// parameters (with default values) and the body keyword (async / sync*).
  String get signature {
    final b = body;
    return norm([
      if (m?.isStatic ?? false) 'static',
      returnType?.toSource() ?? '',
      kind,
      name,
      typeParams?.toSource() ?? '',
      params?.toSource() ?? '',
      b.keyword?.lexeme ?? '',
      b.star?.lexeme ?? '',
    ].join(' '));
  }

  String get bodySource => norm(body.toSource());

  String get tpNames => typeParams == null
      ? ''
      : typeParams!.typeParameters.map((t) => t.name.lexeme).join(', ');
}

class PackageIndex {
  PackageIndex(this.dir, this.pkg);

  final String dir;
  final String pkg;
  final units = <String, Unit>{};
  final exes = <String, Exe>{};
  final boxes = <String, Box>{}; // key: rel::name
  final topVars = <String, VariableDeclaration>{}; // key: rel::name
  final topVarLists = <String, VariableDeclarationList>{};
  final topDecls = <String, CompilationUnitMember>{}; // every top-level declaration: rel::name

  static Future<PackageIndex> load(String dir) async {
    final abs = p.normalize(p.absolute(dir));
    final pubspec = File(p.join(abs, 'pubspec.yaml')).readAsStringSync();
    final pkg = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1)!;
    final idx = PackageIndex(abs, pkg);
    final lib = p.join(abs, 'lib');
    final coll = AnalysisContextCollection(includedPaths: [abs]);
    final ctx = coll.contextFor(lib);
    final files = ctx.contextRoot
        .analyzedFiles()
        .where((f) => f.endsWith('.dart') && p.isWithin(lib, f))
        .toList()
      ..sort();
    for (final f in files) {
      final r = await ctx.currentSession.getResolvedUnit(f);
      if (r is! ResolvedUnitResult) continue;
      final errors = r.diagnostics.where((d) => d.severity.name == 'ERROR').toList();
      if (errors.isNotEmpty) {
        throw StateError('$f has errors: ${errors.map((e) => e.message).join('; ')}');
      }
      final rel = p.relative(f, from: lib).replaceAll(r'\', '/');
      final unit = Unit(pkg, rel, r);
      idx.units[rel] = unit;
      idx._indexUnit(unit);
    }
    return idx;
  }

  void _indexUnit(Unit u) {
    for (final d in u.ast.declarations) {
      Box? box;
      switch (d) {
        case ClassDeclaration n:
          box = Box(u, n, 'class', n.namePart.typeName.lexeme, n.namePart.typeParameters,
              n.body.members, n.declaredFragment?.element);
        case MixinDeclaration n:
          box = Box(u, n, 'mixin', n.name.lexeme, n.typeParameters, n.body.members,
              n.declaredFragment?.element);
        case EnumDeclaration n:
          box = Box(u, n, 'enum', n.namePart.typeName.lexeme, n.namePart.typeParameters,
              n.body.members, n.declaredFragment?.element);
        case ExtensionDeclaration n:
          final name = n.name?.lexeme ?? 'ext:${n.onClause?.extendedType.toSource()}';
          box = Box(u, n, 'extension', name, n.typeParameters, n.body.members,
              n.declaredFragment?.element);
        case FunctionDeclaration n:
          final e = Exe(u, null, n);
          exes[e.key] = e;
          topDecls['${u.rel}::${n.name.lexeme}'] = n;
        case TopLevelVariableDeclaration n:
          for (final v in n.variables.variables) {
            topVars['${u.rel}::${v.name.lexeme}'] = v;
            topVarLists['${u.rel}::${v.name.lexeme}'] = n.variables;
            topDecls['${u.rel}::${v.name.lexeme}'] = n;
          }
        case GenericTypeAlias n:
          topDecls['${u.rel}::${n.name.lexeme}'] = n;
        default:
          break;
      }
      if (box != null) {
        boxes['${u.rel}::${box.name}'] = box;
        topDecls['${u.rel}::${box.name}'] = d;
        for (final mem in box.members.whereType<MethodDeclaration>()) {
          final e = Exe(u, box, mem);
          exes[e.key] = e;
        }
      }
    }
  }

  /// Names of instance members that take part in overriding (declared with @override anywhere).
  /// Such members dispatch dynamically, so they keep their check and are never re-pointed.
  late final Set<String> dispatchNames = {
    for (final e in exes.values)
      if (e.isInstance && e.isOverride) e.name,
  };

  /// Every variable that can carry an initializer: (key, list, variable, box or null, isInstance).
  Iterable<(String, VariableDeclarationList, VariableDeclaration, Box?, bool)> get initVars sync* {
    for (final entry in topVars.entries) {
      final rel = entry.key.split('::').first;
      yield ('$rel::::${entry.value.name.lexeme}::init', topVarLists[entry.key]!, entry.value, null,
          false);
    }
    for (final b in boxes.values) {
      for (final f in b.fields) {
        for (final v in f.fields.variables) {
          yield ('${b.unit.rel}::${b.name}::${v.name.lexeme}::init', f.fields, v, b, !f.isStatic);
        }
      }
    }
  }

  /// The key of the declaration an element refers to, if it is declared in this package.
  /// Keys look like 'src/a.dart::Box::name' (members) or 'src/a.dart::::name' (top level).
  String? declKey(Element? e) {
    if (e == null) return null;
    final libUri = e.library?.uri.toString() ?? '';
    if (!libUri.startsWith('package:$pkg/')) return null;
    var el = e;
    if (el is PropertyAccessorElement) el = el.variable;
    final rel = el.firstFragment.libraryFragment?.source.uri.toString().replaceFirst('package:$pkg/', '');
    final encl = el.enclosingElement;
    final container = encl is InstanceElement ? (encl.name ?? 'ext:?') : '';
    return '$rel::$container::${el.name}';
  }
}
