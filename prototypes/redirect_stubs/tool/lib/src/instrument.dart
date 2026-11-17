// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// `instrument`: prepares a store build.
//
// For every redirectable function body in lib/ it adds a hidden slot and a guard:
//
//   Function? ota$s1a2b3c4d5;                               // one per function
//   int total() { final ota$f = ota$s1a2b3c4d5;
//                 if (ota$f != null) return ota$f(this) as int; ...original body... }
//
// It also adds what future patches need to reach code they cannot name from another library:
//   - `super` helpers (ota$super$m) on overriding members whose superclass has a concrete one;
//   - public accessors for private members, statics, top-level declarations and types (ota$p...).
// Everything generated is marked @pragma('vm:entry-point') so the AOT optimizer keeps it.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import 'edits.dart';
import 'model.dart';

const pragma = "@pragma('vm:entry-point')";

class Instrumenter {
  Instrumenter(this.idx, {this.slotPragma = true, this.outline = true, this.skipLeaves = false});

  final PackageIndex idx;
  final bool slotPragma;

  /// Leave tiny leaf functions without a check; a patch re-points their callers instead.
  final bool skipLeaves;
  List<String> get leaves => manifest['leaves'] as List<String>;

  /// Put the patched call path in a separate never-inlined helper, so the hot function only
  /// contains "load slot, compare, rarely call" and stays small enough to inline.
  final bool outline;
  final manifest = <String, Object?>{
    'slots': <String, Object?>{},
    'supers': <String>[],
    'accessors': <String>[], // keys of private declarations that got an accessor
    'leaves': <String>[], // exe keys left without a check (tiny leaves)
  };

  Map<String, Object?> get slots => manifest['slots'] as Map<String, Object?>;
  List<String> get supers => manifest['supers'] as List<String>;
  List<String> get accessors => manifest['accessors'] as List<String>;

  int guards = 0;
  int initSlots = 0;

  /// A tiny leaf may go without a check only if a patch can re-point its callers instead:
  /// no operators (class operators always win over extension operators) and no members that
  /// take part in overriding (callers through a base type would miss the new version).
  bool _leafSkippable(Exe e) =>
      e.kind != 'operator' && !(e.isInstance && idx.dispatchNames.contains(e.name));

  /// Initializers of globals, static fields and instance fields get a slot too:
  ///   final x = (ota$i.. != null ? ota$i..!() : (original));
  /// so a patch can replace an initializer, or re-point the calls inside it. Globals and statics
  /// are initialized lazily (after the patch is installed at start-up); instance fields per object.
  void _initSlots(Unit u, List<Edit> edits, StringBuffer tail) {
    for (final (key, list, v, box, instance) in idx.initVars) {
      if ((box?.unit ?? u) != u || (box == null && !key.startsWith('${u.rel}::'))) continue;
      final init = v.initializer;
      if (init == null || list.isConst) continue;
      if (instance && (box!.hasConstCtor || box.typeParams != null || box.kind == 'enum')) continue;
      final type = list.type?.toSource() ??
          (v.declaredFragment?.element.type.getDisplayString() ?? 'dynamic');
      final withSelf = instance && list.isLate;
      final slot = 'ota\$i${hash10(key)}';
      final fnType = '$type Function(${withSelf ? '${box!.name} self' : ''})';
      final orig = u.src.substring(init.offset, init.end);
      edits.add(Edit(init.offset, init.end,
          '($slot != null ? $slot!(${withSelf ? 'this' : ''}) : ($orig))'));
      tail.writeln('${slotPragma ? '$pragma\n' : ''}$fnType? $slot;');
      slots[key] = {
        'slot': slot,
        'unit': u.rel,
        'replacement': 'ota\$r${hash10(key)}',
        'kind': 'init',
        'self': withSelf,
        'type': type,
      };
      initSlots++;
    }
  }

  void run() {
    for (final u in idx.units.values) {
      final edits = <Edit>[];
      final tail = StringBuffer();
      final boxHelpers = <Box, StringBuffer>{};
      for (final e in idx.exes.values.where((e) => e.unit == u)) {
        if (!e.redirectable) continue;
        if (skipLeaves && e.isTinyLeaf && _leafSkippable(e)) {
          leaves.add(e.key);
          continue;
        }
        _guard(e, edits);
        if (outline) {
          final h = _slowPath(e);
          if (e.box == null) {
            tail.writeln(h);
          } else {
            boxHelpers.putIfAbsent(e.box!, StringBuffer.new).writeln('  $h');
          }
        }
        final type = outline ? '${slotType(e)}?' : 'Function?';
        tail.writeln('${slotPragma ? '$pragma\n' : ''}$type ${e.slot};');
        slots[e.key] = {'slot': e.slot, 'unit': u.rel, 'replacement': e.replacement};
        guards++;
      }
      _initSlots(u, edits, tail);
      for (final box in idx.boxes.values.where((b) => b.unit == u)) {
        final hb = boxHelpers[box];
        if (hb != null) {
          final close = box.node.endToken.offset;
          edits.add(Edit(close, close, '\n  // ---- ota slow paths ----\n$hb'));
        }
        _superHelpers(box, edits);
        _privateAccessors(box, tail);
      }
      _topLevelAccessors(u, tail);
      if (tail.isEmpty) continue;
      final out = '${applyEdits(u.src, edits)}\n'
          '// ---- generated by ota_redirect instrument (store build) ----\n$tail';
      File(p.join(idx.dir, 'lib', u.rel)).writeAsStringSync(out);
    }
    File(p.join(idx.dir, 'ota_manifest.json'))
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(manifest));
  }

  // ---------------------------------------------------------------- guards

  static String callArgs(Exe e) {
    final args = <String>[if (e.isInstance) 'this'];
    for (final fp in e.params?.parameters ?? const <FormalParameter>[]) {
      final n = fp.name!.lexeme;
      args.add(fp.isNamed ? '$n: $n' : n);
    }
    return args.join(', ');
  }

  static String typeArgs(Exe e) {
    final names = [
      if (e.isInstance && (e.box?.typeParams != null))
        ...e.box!.typeParams!.typeParameters.map((t) => t.name.lexeme),
      if (e.typeParams != null) ...e.typeParams!.typeParameters.map((t) => t.name.lexeme),
    ];
    return names.isEmpty ? '' : '<${names.join(', ')}>';
  }

  static String helperName(Exe e) => 'ota\$h${hash10(e.key)}';

  /// Parameters of [e] as plain positional parameters (no defaults, no required/covariant).
  static List<String> plainParams(Exe e) => [
        for (final fp in e.params?.parameters ?? const <FormalParameter>[])
          e.unit.src
              .substring(fp.offset, fp.defaultClause?.offset ?? fp.end)
              .trim()
              .replaceFirst(RegExp(r'^(required\s+)?(covariant\s+)?'), ''),
      ];

  /// The exact function type of a slot: `RT Function<classTPs, methodTPs>(Self self, params)`.
  /// A typed slot keeps the patched call a normal typed call; an untyped `Function` would make
  /// the optimizer treat every closure in the program as dynamically callable.
  static String slotType(Exe e) {
    final rt = e.kind == 'setter' ? 'void' : (e.returnType?.toSource() ?? 'dynamic');
    final tps = [
      if (e.isInstance && e.box?.typeParams != null)
        ...e.box!.typeParams!.typeParameters.map((t) => t.toSource()),
      if (e.typeParams != null) ...e.typeParams!.typeParameters.map((t) => t.toSource()),
    ];
    final req = <String>[], opt = <String>[], named = <String>[];
    if (e.isInstance) req.add('${_selfType(e)} self');
    for (final fp in e.params?.parameters ?? const <FormalParameter>[]) {
      var s = e.unit.src
          .substring(fp.offset, fp.defaultClause?.offset ?? fp.end)
          .trim()
          .replaceFirst(RegExp(r'^covariant\s+'), '');
      final bare = s.replaceFirst(RegExp(r'^required\s+'), '');
      if (bare == fp.name!.lexeme) s = s.replaceFirst(bare, 'dynamic $bare');
      if (fp.isNamed) {
        named.add(s);
      } else if (fp.isOptionalPositional) {
        opt.add(s);
      } else {
        req.add(s);
      }
    }
    final parts = [
      ...req,
      if (opt.isNotEmpty) '[${opt.join(', ')}]',
      if (named.isNotEmpty) '{${named.join(', ')}}',
    ];
    return '$rt Function${tps.isEmpty ? '' : '<${tps.join(', ')}>'}(${parts.join(', ')})';
  }

  static String _selfType(Exe e) {
    final box = e.box!;
    if (box.node is ExtensionDeclaration) {
      return (box.node as ExtensionDeclaration).onClause!.extendedType.toSource();
    }
    return '${box.name}${box.tpNames}';
  }

  /// The out-of-line patched path: `RT helper<TP>(SlotType f, params) => f<TPs>(this, args)`.
  String _slowPath(Exe e) {
    final rt = e.returnType?.toSource();
    final isVoid = e.kind == 'setter' || rt == 'void';
    final isStaticCtx = !e.isInstance && e.box != null;
    final params = ['${slotType(e)} ota\$f', ...plainParams(e)].join(', ');
    final tps = e.typeParams?.toSource() ?? '';
    final call = 'ota\$f${typeArgs(e)}(${callArgs(e)})';
    final head = '@pragma(\'vm:never-inline\') ${isStaticCtx ? 'static ' : ''}';
    if (isVoid) return '$head void ${helperName(e)}$tps($params) { $call; }';
    return '$head${rt == null ? '' : '$rt '}${helperName(e)}$tps($params) => $call;';
  }

  void _guard(Exe e, List<Edit> edits) {
    if (outline) return _guardOutlined(e, edits);
    final body = e.body;
    final rt = e.returnType?.toSource();
    final call = 'ota\$f${typeArgs(e)}(${callArgs(e)})';
    final isVoid = e.kind == 'setter' || rt == 'void';
    final String onPatched;
    if (body.isGenerator) {
      onPatched = '{ yield* ${rt == null ? call : '($call as $rt)'}; return; }';
    } else if (isVoid) {
      onPatched = '{ $call; return; }';
    } else if (body.isAsynchronous) {
      onPatched = 'return ${rt == null ? 'await $call' : '($call as $rt)'};';
    } else {
      onPatched = 'return ${rt == null ? call : '$call as $rt'};';
    }
    final guard = 'final ota\$f = ${e.slot}; if (ota\$f != null) $onPatched';
    switch (body) {
      case BlockFunctionBody b:
        edits.add(Edit(b.block.leftBracket.end, b.block.leftBracket.end, ' $guard'));
      case ExpressionFunctionBody b:
        final expr = e.unit.src.substring(b.expression.offset, b.expression.end);
        final stmt = isVoid ? '$expr;' : 'return $expr;';
        edits.add(Edit(b.functionDefinition.offset, b.end, '{ $guard $stmt }'));
      default:
        break;
    }
  }

  void _guardOutlined(Exe e, List<Edit> edits) {
    final body = e.body;
    final rt = e.returnType?.toSource();
    final isVoid = e.kind == 'setter' || rt == 'void';
    final tpn = e.tpNames.isEmpty ? '' : '<${e.tpNames}>';
    final args = [
      'ota\$f',
      for (final fp in e.params?.parameters ?? const <FormalParameter>[]) fp.name!.lexeme,
    ].join(', ');
    final call = '${helperName(e)}$tpn($args)';
    final String onPatched;
    if (body.isGenerator) {
      onPatched = '{ yield* $call; return; }';
    } else if (isVoid) {
      onPatched = '{ $call; return; }';
    } else {
      onPatched = 'return $call;';
    }
    final guard = 'final ota\$f = ${e.slot}; if (ota\$f != null) $onPatched';
    switch (body) {
      case BlockFunctionBody b:
        edits.add(Edit(b.block.leftBracket.end, b.block.leftBracket.end, ' $guard'));
      case ExpressionFunctionBody b:
        final expr = e.unit.src.substring(b.expression.offset, b.expression.end);
        final stmt = isVoid ? '$expr;' : 'return $expr;';
        edits.add(Edit(b.functionDefinition.offset, b.end, '{ $guard $stmt }'));
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- super helpers

  void _superHelpers(Box box, List<Edit> edits) {
    final el = box.element;
    if (el is! InterfaceElement || box.kind == 'extension') return;
    final lib = el.library;
    final buf = StringBuffer();
    for (final e in idx.exes.values.where((e) => e.box == box && e.isInstance && e.isOverride)) {
      final name = e.name;
      final hasConcreteSuper = switch (e.kind) {
        'method' => el.thisType.lookUpMethod(name, lib, concrete: true, inherited: true) != null,
        'getter' => el.thisType.lookUpGetter(name, lib, concrete: true, inherited: true) != null,
        'setter' => el.thisType.lookUpSetter(name, lib, concrete: true, inherited: true) != null,
        _ => false,
      };
      if (!hasConcreteSuper) continue;
      final rt = e.returnType == null ? '' : '${e.returnType!.toSource()} ';
      final params = e.params?.toSource() ?? '';
      final args = callArgs(e).replaceFirst(RegExp(r'^this(, )?'), '');
      final tps = e.typeParams?.toSource() ?? '';
      final tpn = e.tpNames.isEmpty ? '' : '<${e.tpNames}>';
      final helper = switch (e.kind) {
        'method' => '$rt ota\$super\$$name$tps$params => super.$name$tpn($args);',
        'getter' => '${rt}get ota\$super\$$name => super.$name;',
        _ => 'set ota\$super\$$name$params => super.$name = $args;',
      };
      buf.writeln('  $pragma\n  $helper');
      supers.add('${box.unit.rel}::${box.name}::$name');
    }
    if (buf.isEmpty) return;
    final close = box.node.endToken.offset;
    edits.add(Edit(close, close, '\n  // ---- ota super helpers ----\n$buf'));
  }

  // ---------------------------------------------------------------- private accessors

  static String _typeOf(VariableDeclarationList list, VariableDeclaration v) =>
      list.type?.toSource() ??
      (v.declaredFragment?.element.type.getDisplayString() ?? 'dynamic');

  void _privateAccessors(Box box, StringBuffer tail) {
    if (box.kind == 'extension') return;
    final inst = StringBuffer();
    final b = box.name;
    for (final fd in box.fields) {
      final list = fd.fields;
      for (final v in list.variables) {
        final n = v.name.lexeme;
        if (!n.startsWith('_')) continue;
        final t = _typeOf(list, v);
        final mutable = !list.isFinal && !list.isConst;
        final key = '${box.unit.rel}::$b::$n';
        if (fd.isStatic) {
          tail.writeln('$pragma\n$t get ota\$p\$$b\$$n => $b.$n;');
          if (mutable) tail.writeln('$pragma\nset ota\$p\$$b\$$n($t v) => $b.$n = v;');
        } else {
          inst.writeln('  $pragma\n  $t get ota\$p$n => this.$n;');
          if (mutable) inst.writeln('  $pragma\n  set ota\$p$n($t v) => this.$n = v;');
        }
        accessors.add(key);
      }
    }
    for (final e in idx.exes.values.where((e) => e.box == box && e.name.startsWith('_'))) {
      final n = e.name;
      final rt = e.returnType == null ? '' : '${e.returnType!.toSource()} ';
      final params = e.params?.toSource() ?? '';
      final args = callArgs(e).replaceFirst(RegExp(r'^this(, )?'), '');
      final tps = e.typeParams?.toSource() ?? '';
      final tpn = e.tpNames.isEmpty ? '' : '<${e.tpNames}>';
      final target = e.isInstance ? 'this' : b;
      final prefix = e.isInstance ? 'ota\$p' : 'ota\$p\$$b\$';
      final line = switch (e.kind) {
        'getter' => '${rt}get $prefix$n => $target.$n;',
        'setter' => 'set $prefix$n$params => $target.$n = $args;',
        _ => '$rt$prefix$n$tps$params => $target.$n$tpn($args);',
      };
      if (e.isInstance) {
        inst.writeln('  $pragma\n  $line');
      } else {
        tail.writeln('$pragma\n$line');
      }
      accessors.add('${box.unit.rel}::$b::$n');
    }
    if (inst.isNotEmpty) {
      final on = '$b${box.tpNames}';
      tail.writeln('extension ota\$p\$$b${box.tpDecl} on $on {\n$inst}');
    }
    if (box.isPrivate) {
      tail.writeln('typedef ota\$p$b${box.tpDecl} = $b${box.tpNames};');
      accessors.add('${box.unit.rel}::::$b');
    }
  }

  void _topLevelAccessors(Unit u, StringBuffer tail) {
    for (final d in u.ast.declarations) {
      switch (d) {
        case FunctionDeclaration f when f.name.lexeme.startsWith('_'):
          final e = Exe(u, null, f);
          final n = e.name;
          final rt = e.returnType == null ? '' : '${e.returnType!.toSource()} ';
          final params = e.params?.toSource() ?? '';
          final tps = e.typeParams?.toSource() ?? '';
          final tpn = e.tpNames.isEmpty ? '' : '<${e.tpNames}>';
          final line = switch (e.kind) {
            'getter' => '${rt}get ota\$p$n => $n;',
            'setter' => 'set ota\$p$n$params => $n = ${callArgs(e)};',
            _ => '$rt ota\$p$n$tps$params => $n$tpn(${callArgs(e)});',
          };
          tail.writeln('$pragma\n$line');
          accessors.add('${u.rel}::::$n');
        case TopLevelVariableDeclaration t:
          for (final v in t.variables.variables) {
            final n = v.name.lexeme;
            if (!n.startsWith('_')) continue;
            final ty = _typeOf(t.variables, v);
            tail.writeln('$pragma\n$ty get ota\$p$n => $n;');
            if (!t.variables.isFinal && !t.variables.isConst) {
              tail.writeln('$pragma\nset ota\$p$n($ty v) => $n = v;');
            }
            accessors.add('${u.rel}::::$n');
          }
        case GenericTypeAlias a when a.name.lexeme.startsWith('_'):
          final n = a.name.lexeme;
          final tps = a.typeParameters?.toSource() ?? '';
          final tpn = a.typeParameters == null
              ? ''
              : '<${a.typeParameters!.typeParameters.map((t) => t.name.lexeme).join(', ')}>';
          tail.writeln('typedef ota\$p$n$tps = $n$tpn;');
          accessors.add('${u.rel}::::$n');
        default:
          break;
      }
    }
  }
}
