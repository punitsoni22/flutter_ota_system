// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// `patch`: turns the difference between two versions of a package into patch libraries.
//
// Every change is shipped by the cheapest mechanism that expresses it (chosen per declaration):
//   body          changed function body, same signature        -> replacement behind its slot
//   const-user    unchanged function using a changed constant   -> re-compiled replacement
//   init          changed or re-pointed initializer             -> replacement behind its init slot
//   repoint       signature/default change, changed tiny leaf, global whose type changed
//                                                              -> new version + every user re-pointed
//   add           new file / class / function / member / static -> added by the patch
//   side-field    new field on an existing class                -> side table (Expando) + accessors;
//                                                                 constructor helper for new params
//   copy          class whose structure cannot be patched in place (widget: level 2; other: level 3)
//                                                              -> fresh copy of the class, users re-pointed
//   critical      --critical: whole-app copy (level 4)
// Patch level: 1 = bodies/constants/initializers only, 2 = additions, side fields, re-pointing,
// widget copies, 3 = copies of non-widget classes, 4 = whole-app copy.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import 'edits.dart';
import 'model.dart';

const _pragma = "@pragma('vm:entry-point')";

class SideField {
  SideField(this.box, this.list, this.v, this.type, this.defaultSrc, this.mutable);

  final Box box;
  final VariableDeclarationList list;
  final VariableDeclaration v;
  final String type;
  final String defaultSrc; // expression text (v2), already a valid default
  final bool mutable;

  String get name => v.name.lexeme;
  String get key => '${box.unit.rel}::${box.name}::$name';
  String get table => '_ota\$sf${hash10(key)}';
}

class Planner {
  Planner(this.v1, this.v2, this.manifest, {this.critical = false})
      : accessors = (manifest['accessors'] as List).cast<String>().toSet(),
        supers = (manifest['supers'] as List).cast<String>().toSet(),
        slots = (manifest['slots'] as Map).cast<String, Object?>(),
        leaves = ((manifest['leaves'] as List?) ?? const []).cast<String>().toSet();

  final PackageIndex v1, v2;
  final Map<String, Object?> manifest;
  final bool critical;
  final Set<String> accessors, supers, leaves;
  final Map<String, Object?> slots;

  // ------------------------------------------------------------------ decisions
  final t1 = <String, String>{}; // exe key -> reason
  final inits = <String, String>{}; // init slot key -> reason
  final repointed = <String, String>{}; // decl key (rel::Box::name) -> new name
  final repointExe = <String, Exe>{}; // decl key -> v2 function-like declaration
  final repointVar = <String, (VariableDeclarationList, VariableDeclaration, Box?)>{};
  final sideFields = <String, SideField>{}; // decl key -> side field
  final ctorHelpers = <String, String>{}; // 'rel::Box::ctorName' -> helper name
  final ctorHelperDecls = <String, (Box, ConstructorDeclaration, ConstructorDeclaration)>{};
  final newMembers = <String, List<Exe>>{}; // box key -> new instance members
  final newStatics = <String, String>{}; // decl key -> patch top-level name
  final newStaticDecls = <String, ClassMember>{};
  final changedConsts = <String, String>{}; // decl key -> patch const name
  final newTop = <String, CompilationUnitMember>{}; // rel::name -> declaration
  final newUnits = <String>{};
  final copied = <String, String>{}; // box key -> copy name
  final unavailable = <String>{};
  final report = <String, List<String>>{
    'patched': [], 'initializers': [], 'repointed': [], 'side_fields': [], 'added': [],
    'copied': [], 'refused': [], 'dropped': [], 'notes': [],
  };

  late final Set<String> v1Decls = _declKeys(v1);
  final providedNew = <String>{};
  late final dispatchNames = {...v1.dispatchNames, ...v2.dispatchNames};

  int level = 0;
  void _atLeast(int l) => level = max(level, l);

  static Set<String> _declKeys(PackageIndex x) {
    final s = <String>{};
    for (final b in x.boxes.values) {
      s.add('${b.unit.rel}::::${b.name}');
      for (final f in b.fields) {
        for (final v in f.fields.variables) {
          s.add('${b.unit.rel}::${b.name}::${v.name.lexeme}');
        }
      }
      if (b.node is EnumDeclaration) {
        for (final c in (b.node as EnumDeclaration).body.constants) {
          s.add('${b.unit.rel}::${b.name}::${c.name.lexeme}');
        }
      }
    }
    for (final e in x.exes.values) {
      s.add('${e.unit.rel}::${e.box?.name ?? ''}::${e.name}');
    }
    for (final k in x.topDecls.keys) {
      final i = k.indexOf('::');
      s.add('${k.substring(0, i)}::::${k.substring(i + 2)}');
    }
    return s;
  }

  static String _typeSig(VariableDeclarationList l) =>
      norm('${l.keyword?.lexeme ?? ''} ${l.isLate ? 'late' : ''} ${l.type?.toSource() ?? ''}');

  static String _ctorSig(ConstructorDeclaration c) =>
      norm(c.toSource().replaceAll(RegExp(r'@\w+(\([^)]*\))?'), ''));

  String? _inferredType(VariableDeclaration v) =>
      v.declaredFragment?.element.type.getDisplayString();

  bool _slotted(String exeKey) => slots.containsKey(exeKey);

  /// Instance members that dispatch dynamically can't be re-pointed (callers through a base
  /// type would miss the new version); their class is copied instead.
  bool _repointable(Exe e) =>
      !(e.isInstance && dispatchNames.contains(e.name)) && e.kind != 'operator' && !e.isAbstract;

  // ------------------------------------------------------------------ planning

  void plan() {
    if (critical) {
      _atLeast(4);
      report['notes']!.add('critical: the whole app ships as a copy (level 4)');
      return;
    }
    for (final rel in v2.units.keys) {
      if (!v1.units.containsKey(rel)) {
        newUnits.add(rel);
        report['added']!.add('new file $rel');
        _atLeast(2);
      }
    }
    for (final entry in v2.boxes.entries) {
      final b2 = entry.value;
      if (newUnits.contains(b2.unit.rel)) continue;
      final b1 = v1.boxes[entry.key];
      if (b1 == null) {
        newTop[entry.key] = b2.node;
        _atLeast(2);
        continue;
      }
      _compareBox(entry.key, b1, b2);
    }
    _compareFunctions();
    _compareGlobals();
    _closure();
    _dropCoveredByCopies();
    _collectProvided();
    if (level == 0 && (t1.isNotEmpty || inits.isNotEmpty || changedConsts.isNotEmpty)) _atLeast(1);
  }

  void _copy(String boxKey, String why) {
    if (copied.containsKey(boxKey)) return;
    final b = v2.boxes[boxKey]!;
    copied[boxKey] = '${b.name}\$ota';
    final lvl = b.isWidgetLike ? 2 : 3;
    _atLeast(lvl);
    report['copied']!.add('$boxKey (level $lvl: $why)');
  }

  void _compareBox(String k, Box b1, Box b2) {
    final reasons = <String>[];
    if (b1.header != b2.header) reasons.add('class header changed');
    if (b1.enumConstants.join(',') != b2.enumConstants.join(',')) reasons.add('enum values changed');

    final f1 = {
      for (final f in b1.fields.where((f) => !f.isStatic))
        for (final v in f.fields.variables) v.name.lexeme: (f.fields, v),
    };
    final f2 = {
      for (final f in b2.fields.where((f) => !f.isStatic))
        for (final v in f.fields.variables) v.name.lexeme: (f.fields, v),
    };
    final added = <String>[];
    for (final name in f2.keys) {
      final now = f2[name]!;
      final was = f1[name];
      if (was == null) {
        added.add(name);
        continue;
      }
      if (_typeSig(was.$1) != _typeSig(now.$1)) {
        reasons.add('type of field $name changed');
      } else if (norm(was.$2.initializer?.toSource() ?? '') !=
          norm(now.$2.initializer?.toSource() ?? '')) {
        final key = '${b2.unit.rel}::${b2.name}::$name::init';
        if (slots.containsKey(key)) {
          inits[key] = 'initializer changed';
        } else {
          reasons.add('initializer of field $name changed (no initializer slot)');
        }
      }
    }
    // static fields: new ones are added, constants re-pointed, initializers replaced
    for (final f in b2.fields.where((f) => f.isStatic)) {
      for (final v in f.fields.variables) {
        final declKey = '${b2.unit.rel}::${b2.name}::${v.name.lexeme}';
        final old = b1.fields
            .where((x) => x.isStatic)
            .expand((x) => x.fields.variables.map((y) => (x, y)))
            .where((t) => t.$2.name.lexeme == v.name.lexeme)
            .firstOrNull;
        if (old == null) {
          newStatics[declKey] = 'ota\$n\$${b2.name}\$${v.name.lexeme}';
          newStaticDecls[declKey] = f;
          _atLeast(2);
        } else if (_typeSig(old.$1.fields) != _typeSig(f.fields)) {
          repointVar[declKey] = (f.fields, v, b2);
        } else if (norm(old.$2.initializer?.toSource() ?? '') !=
            norm(v.initializer?.toSource() ?? '')) {
          if (f.fields.isConst) {
            changedConsts[declKey] = 'ota\$c\$${b2.name}\$${v.name.lexeme}';
          } else if (slots.containsKey('$declKey::init')) {
            inits['$declKey::init'] = 'initializer changed';
          } else {
            repointVar[declKey] = (f.fields, v, b2);
          }
        }
      }
    }
    // constructors: identical, or "old constructor + parameters that only set new fields"
    final c1 = {for (final c in b1.ctors) c.name?.lexeme ?? '': c};
    final c2 = {for (final c in b2.ctors) c.name?.lexeme ?? '': c};
    final ctorNotes = <String>[];
    for (final name in c2.keys) {
      final a = c1[name];
      final b = c2[name]!;
      if (a == null) {
        reasons.add('new constructor ${name.isEmpty ? b2.name : name}');
        continue;
      }
      if (_ctorSig(a) == _ctorSig(b)) continue;
      if (_onlyAddsFieldParams(a, b, added)) {
        ctorNotes.add(name);
      } else {
        reasons.add('constructor ${name.isEmpty ? b2.name : name} changed');
      }
    }
    // new fields become side fields when they have a default for old objects
    final sides = <SideField>[];
    for (final name in added) {
      final (list, v) = f2[name]!;
      final sf = _sideField(b2, list, v, c2.values);
      if (sf == null) {
        reasons.add('new field $name has no default for existing objects');
      } else {
        sides.add(sf);
      }
    }
    // new overrides need the class (dispatch tables are fixed)
    for (final e in v2.exes.values.where((e) => e.box == b2 && e.isOverride)) {
      if (!v1.exes.containsKey(e.key)) reasons.add('new override ${e.name}');
    }
    if (reasons.isNotEmpty || (b2.isWidgetLike && (sides.isNotEmpty || ctorNotes.isNotEmpty))) {
      _copy(k, reasons.isEmpty ? 'widget gained fields' : reasons.join(', '));
      return;
    }
    for (final sf in sides) {
      sideFields[sf.key] = sf;
      report['side_fields']!.add('${sf.key} (${sf.type}, default ${sf.defaultSrc})');
      _atLeast(2);
    }
    for (final name in ctorNotes) {
      final key = '${b2.unit.rel}::${b2.name}::$name';
      ctorHelpers[key] = 'ota\$ctor\$${b2.name}\$${name.isEmpty ? 'new' : name}';
      ctorHelperDecls[key] = (b2, c1[name]!, c2[name]!);
    }
  }

  /// True when [b] is [a] plus parameters `this.x` that only initialize new fields.
  static bool _onlyAddsFieldParams(ConstructorDeclaration a, ConstructorDeclaration b,
      List<String> newFields) {
    if (norm(a.initializers.map((i) => i.toSource()).join(',')) !=
            norm(b.initializers.map((i) => i.toSource()).join(',')) ||
        norm(a.body.toSource()) != norm(b.body.toSource()) ||
        a.factoryKeyword != null ||
        b.redirectedConstructor != null) {
      return false;
    }
    final pa = a.parameters.parameters.map((x) => norm(x.toSource())).toList();
    final pb = b.parameters.parameters.toList();
    final rest = <FormalParameter>[];
    for (final x in pb) {
      final i = pa.indexOf(norm(x.toSource()));
      if (i >= 0) {
        pa.removeAt(i);
      } else {
        rest.add(x);
      }
    }
    if (pa.isNotEmpty) return false;
    return rest.every((x) => x is FieldFormalParameter && newFields.contains(x.name.lexeme) &&
        !x.isRequiredPositional);
  }

  SideField? _sideField(Box b, VariableDeclarationList list, VariableDeclaration v,
      Iterable<ConstructorDeclaration> ctors) {
    if (b.kind == 'enum' || b.kind == 'extension' || list.isLate || b.typeParams != null) {
      return null;
    }
    final type = list.type?.toSource() ?? _inferredType(v);
    if (type == null || type == 'dynamic') return null;
    String? def = v.initializer?.toSource();
    if (def == null) {
      for (final c in ctors) {
        for (final fp in c.parameters.parameters) {
          if (fp is FieldFormalParameter && fp.name.lexeme == v.name.lexeme) {
            def ??= fp.defaultClause?.value.toSource();
          }
        }
      }
    }
    def ??= type.endsWith('?') ? 'null' : null;
    if (def == null) return null;
    return SideField(b, list, v, type, def, !list.isFinal);
  }

  void _compareFunctions() {
    for (final e2 in v2.exes.values) {
      if (newUnits.contains(e2.unit.rel)) continue;
      final boxKey = e2.box == null ? null : '${e2.unit.rel}::${e2.box!.name}';
      if (boxKey != null && (copied.containsKey(boxKey) || !v1.boxes.containsKey(boxKey))) continue;
      final declKey = '${e2.unit.rel}::${e2.box?.name ?? ''}::${e2.name}';
      final e1 = v1.exes[e2.key];
      if (e1 == null) {
        if (e2.box == null) {
          newTop['${e2.unit.rel}::${e2.name}'] = e2.node as CompilationUnitMember;
        } else if (e2.isOverride) {
          continue; // handled by the class comparison (copy)
        } else if (e2.isInstance) {
          newMembers.putIfAbsent(boxKey!, () => []).add(e2);
        } else {
          newStatics[declKey] = 'ota\$n\$${e2.box!.name}\$${e2.name}';
          newStaticDecls[declKey] = e2.node as ClassMember;
        }
        _atLeast(2);
        continue;
      }
      if (!e1.redirectable) continue;
      final sigChanged = e1.signature != e2.signature;
      final bodyChanged = e1.bodySource != e2.bodySource;
      if (!sigChanged && !bodyChanged) continue;
      if (sigChanged || !_slotted(e2.key)) {
        if (_repointable(e2)) {
          _repoint(declKey, e2, sigChanged ? 'signature changed' : 'tiny leaf changed');
        } else if (boxKey != null) {
          _copy(boxKey, 'signature of ${e2.name} changed and it dispatches dynamically');
        } else {
          _refuse(declKey, 'cannot be re-pointed');
        }
      } else {
        t1[e2.key] = 'body';
      }
    }
  }

  void _repoint(String declKey, Exe e2, String why) {
    if (repointed.containsKey(declKey)) return;
    repointed[declKey] = e2.isInstance ? 'ota\$v_${e2.name}' : 'ota\$v${hash10(declKey)}';
    repointExe[declKey] = e2;
    report['repointed']!.add('$declKey ($why)');
    _atLeast(2);
  }

  void _compareGlobals() {
    for (final entry in v2.topVars.entries) {
      final rel = entry.key.split('::').first;
      if (newUnits.contains(rel)) continue;
      final v2v = entry.value;
      final v1v = v1.topVars[entry.key];
      final list2 = v2.topVarLists[entry.key]!;
      if (v1v == null) {
        newTop[entry.key] = v2.topDecls[entry.key]!;
        _atLeast(2);
        continue;
      }
      final list1 = v1.topVarLists[entry.key]!;
      final key = '$rel::::${v2v.name.lexeme}';
      final typeSame = _typeSig(list1) == _typeSig(list2) &&
          (list1.type != null || _inferredType(v1v) == _inferredType(v2v));
      final initSame =
          norm(v1v.initializer?.toSource() ?? '') == norm(v2v.initializer?.toSource() ?? '');
      if (typeSame && initSame) continue;
      if (list2.isConst && list1.isConst && typeSame) {
        changedConsts[key] = 'ota\$c\$\$${v2v.name.lexeme}';
      } else if (typeSame && slots.containsKey('$key::init')) {
        inits['$key::init'] = 'initializer changed';
      } else {
        repointVar[key] = (list2, v2v, null);
      }
    }
    for (final k in repointVar.keys) {
      repointed[k] = 'ota\$g${hash10(k)}';
      report['repointed']!.add('$k (variable type or initializer changed)');
      _atLeast(2);
    }
  }

  /// Fixpoint: copies spread through class structure and signatures; every function or
  /// initializer that uses something re-pointed, copied or re-valued is re-patched (or itself
  /// re-pointed when it is a tiny leaf without a check).
  void _closure() {
    var changed = true;
    var guard = 0;
    while (changed && guard++ < 50) {
      changed = false;
      // structure: classes whose supertypes or fields name a copied class
      for (final entry in v2.boxes.entries) {
        final k = entry.key;
        final b = entry.value;
        if (copied.containsKey(k) || newUnits.contains(b.unit.rel) || !v1.boxes.containsKey(k)) {
          continue;
        }
        final structural = <AstNode>[
          if (b.node is ClassDeclaration) ...[
            if ((b.node as ClassDeclaration).extendsClause != null)
              (b.node as ClassDeclaration).extendsClause!,
            if ((b.node as ClassDeclaration).implementsClause != null)
              (b.node as ClassDeclaration).implementsClause!,
            if ((b.node as ClassDeclaration).withClause != null)
              (b.node as ClassDeclaration).withClause!,
          ],
          ...b.fields.where((f) => !f.isStatic),
        ];
        if (structural.any(_mentionsCopied)) {
          _copy(k, 'its structure names a copied class');
          changed = true;
        }
      }
      // signatures and globals that name a copied class
      for (final e2 in v2.exes.values) {
        final boxKey = e2.box == null ? null : '${e2.unit.rel}::${e2.box!.name}';
        if (boxKey != null && (copied.containsKey(boxKey) || !v1.boxes.containsKey(boxKey))) {
          continue;
        }
        if (newUnits.contains(e2.unit.rel) || !v1.exes.containsKey(e2.key)) continue;
        final declKey = '${e2.unit.rel}::${e2.box?.name ?? ''}::${e2.name}';
        if (repointed.containsKey(declKey)) continue;
        final sigNodes = <AstNode>[
          if (e2.returnType != null) e2.returnType!,
          if (e2.params != null) e2.params!,
        ];
        if (sigNodes.any(_mentionsCopied)) {
          if (_repointable(e2)) {
            _repoint(declKey, e2, 'signature names a copied class');
          } else {
            _copy(boxKey!, 'member ${e2.name} names a copied class and dispatches dynamically');
          }
          changed = true;
        }
      }
      for (final (key, list, v, box, _) in v2.initVars) {
        final declKey = key.substring(0, key.length - '::init'.length);
        if (box != null && (copied.containsKey('${box.unit.rel}::${box.name}'))) continue;
        if (repointed.containsKey(declKey) || list.type == null) continue;
        if (_mentionsCopied(list.type!)) {
          repointVar[declKey] = (list, v, box);
          repointed[declKey] = 'ota\$g${hash10(declKey)}';
          report['repointed']!.add('$declKey (type names a copied class)');
          changed = true;
        }
      }
      // users
      for (final e2 in v2.exes.values) {
        final boxKey = e2.box == null ? null : '${e2.unit.rel}::${e2.box!.name}';
        if (boxKey != null && (copied.containsKey(boxKey) || !v1.boxes.containsKey(boxKey))) {
          continue;
        }
        if (newUnits.contains(e2.unit.rel) || !v1.exes.containsKey(e2.key)) continue;
        final declKey = '${e2.unit.rel}::${e2.box?.name ?? ''}::${e2.name}';
        if (t1.containsKey(e2.key) || repointed.containsKey(declKey)) continue;
        if (!_usesChanged(e2.body)) continue;
        if (_slotted(e2.key)) {
          t1[e2.key] = 'user of a changed declaration';
        } else if (_repointable(e2)) {
          _repoint(declKey, e2, 'tiny leaf that uses a changed declaration');
        } else {
          _copy(boxKey!, 'leaf ${e2.name} uses a changed declaration and dispatches dynamically');
        }
        changed = true;
      }
      for (final (key, _, v, box, _) in v2.initVars) {
        final declKey = key.substring(0, key.length - '::init'.length);
        if (inits.containsKey(key) || repointed.containsKey(declKey)) continue;
        if (box != null && copied.containsKey('${box.unit.rel}::${box.name}')) continue;
        if (box != null && !v1.boxes.containsKey('${box.unit.rel}::${box.name}')) continue;
        final init = v.initializer;
        if (init == null || !_usesChanged(init)) continue;
        if (slots.containsKey(key)) {
          inits[key] = 'uses a changed declaration';
          changed = true;
        } else if (!changedConsts.containsKey(declKey)) {
          report['notes']!.add('$declKey: initializer uses a changed declaration but has no slot '
              '(const or generic-class field); it keeps the old value');
        }
      }
    }
  }

  /// A copied class carries all its members, fields and initializers: nothing of it is
  /// patched separately.
  void _dropCoveredByCopies() {
    bool inCopy(String key) {
      final parts = key.split('::');
      return parts.length > 1 && parts[1].isNotEmpty && copied.containsKey('${parts[0]}::${parts[1]}');
    }

    t1.removeWhere((k, _) => inCopy(k));
    inits.removeWhere((k, _) => inCopy(k));
    for (final k in repointed.keys.where(inCopy).toList()) {
      repointed.remove(k);
      repointExe.remove(k);
      repointVar.remove(k);
    }
    sideFields.removeWhere((k, _) => inCopy(k));
    ctorHelpers.removeWhere((k, _) => inCopy(k));
    ctorHelperDecls.removeWhere((k, _) => inCopy(k));
    newMembers.removeWhere((k, _) => copied.containsKey(k));
    for (final k in newStatics.keys.where(inCopy).toList()) {
      newStatics.remove(k);
      newStaticDecls.remove(k);
    }
    changedConsts.removeWhere((k, _) => inCopy(k));
  }

  bool _usesChanged(AstNode node) {
    var hit = false;
    node.accept(_Finder((n) {
      if (hit) return;
      Element? e;
      if (n is SimpleIdentifier) e = n.element;
      if (n is NamedType) e = n.element;
      if (n is InstanceCreationExpression) {
        final c = n.constructorName.element;
        if (c != null && ctorHelpers.containsKey(_ctorKey(c))) hit = true;
        return;
      }
      if (e == null) return;
      if (_isCopied(e)) {
        hit = true;
        return;
      }
      var el = e;
      if (el is PropertyAccessorElement) el = el.variable;
      final k = v2.declKey(el);
      if (k != null && (changedConsts.containsKey(k) || repointed.containsKey(k))) hit = true;
    }));
    return hit;
  }

  String _ctorKey(ConstructorElement c) {
    final cls = v2.declKey(c.enclosingElement)?.split('::') ?? ['', '', ''];
    final n = c.name ?? '';
    return '${cls[0]}::${cls[2]}::${n == 'new' ? '' : n}';
  }

  void _collectProvided() {
    providedNew
      ..addAll(newMembers.values.expand((l) => l).map(
          (e) => '${e.unit.rel}::${e.box!.name}::${e.name}'))
      ..addAll(newStatics.keys)
      ..addAll(sideFields.keys)
      ..addAll(repointed.keys)
      ..addAll(newTop.keys.map((k) => k.replaceFirst('::', '::::')));
    for (final k in newTop.keys) {
      final rel = k.split('::').first;
      final box = v2.boxes[k];
      if (box == null) continue;
      for (final e in v2.exes.values.where((e) => e.box == box)) {
        providedNew.add('$rel::${box.name}::${e.name}');
      }
      for (final f in box.fields) {
        for (final v in f.fields.variables) {
          providedNew.add('$rel::${box.name}::${v.name.lexeme}');
        }
      }
    }
  }

  void _refuse(String key, String why) {
    unavailable.add(key);
    report['refused']!.add('$key: $why');
  }

  bool _mentionsCopied(AstNode node) {
    var hit = false;
    node.accept(_Finder((n) {
      if (n is NamedType && _isCopied(n.element)) hit = true;
      if (n is SimpleIdentifier && _isCopied(n.element)) hit = true;
    }));
    return hit;
  }

  bool _isCopied(Element? e) {
    if (e is! InterfaceElement && e is! ConstructorElement) return false;
    final cls = e is ConstructorElement ? e.enclosingElement : e!;
    final k = v2.declKey(cls);
    if (k == null) return false;
    final parts = k.split('::');
    return copied.containsKey('${parts[0]}::${parts[2]}');
  }

  // ------------------------------------------------------------------ availability

  String? problemFor(Element? e) {
    if (e == null) return null;
    var el = e;
    if (el is PropertyAccessorElement) el = el.variable;
    final encl = el.enclosingElement;
    if (encl is! LibraryElement && encl is! InstanceElement) return null;
    final k = v2.declKey(el);
    if (k == null) return null;
    final parts = k.split('::');
    if (newUnits.contains(parts[0])) return null;
    if (parts[1].isNotEmpty && copied.containsKey('${parts[0]}::${parts[1]}')) return null;
    if (parts[1].isEmpty && copied.containsKey('${parts[0]}::${parts[2]}')) return null;
    if (changedConsts.containsKey(k) || repointed.containsKey(k)) return null;
    if (unavailable.contains(k)) return 'depends on $k, which is not patchable';
    if (v1Decls.contains(k)) {
      if (parts.last.startsWith('_') && !accessors.contains(k)) {
        return 'uses private $k, which has no accessor in the store build';
      }
      return null;
    }
    if (providedNew.contains(k)) return null;
    return 'depends on new $k, which this patch cannot provide';
  }

  // ------------------------------------------------------------------ metrics

  Map<String, Object?> metrics() {
    var added = 0, removed = 0, files = 0;
    for (final rel in {...v1.units.keys, ...v2.units.keys}) {
      final a = v1.units[rel]?.src.split('\n') ?? const <String>[];
      final b = v2.units[rel]?.src.split('\n') ?? const <String>[];
      if (a.join('\n') == b.join('\n')) continue;
      files++;
      final common = _lcs(a, b);
      added += b.length - common;
      removed += a.length - common;
    }
    final copiedMembers = copied.keys
        .map((k) => v2.exes.values.where((e) => '${e.unit.rel}::${e.box?.name}' == k).length)
        .fold(0, (x, y) => x + y);
    final interpreted = critical
        ? v2.exes.length
        : t1.length + inits.length + repointed.length + sideFields.length * 2 +
            ctorHelpers.length + newMembers.values.fold(0, (x, l) => x + l.length) +
            newStatics.length + newTop.length + copiedMembers;
    return {
      'level': level,
      'files_changed': files,
      'lines_added': added,
      'lines_removed': removed,
      'interpreted_functions': interpreted,
      'copied_classes': critical ? v2.boxes.length : copied.length,
      'side_fields': sideFields.length,
      'repointed': repointed.length,
    };
  }

  static int _lcs(List<String> a, List<String> b) {
    final prev = List.filled(b.length + 1, 0), cur = List.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]);
      }
      prev.setAll(0, cur);
    }
    return prev[b.length];
  }
}

class _Finder extends GeneralizingAstVisitor<void> {
  _Finder(this.onNode);

  final void Function(AstNode) onNode;

  @override
  void visitNode(AstNode node) {
    onNode(node);
    super.visitNode(node);
  }
}

// ---------------------------------------------------------------------------------- rewriter

/// Rewrites v2 code so it compiles in a patch library next to the store build.
class Rewriter extends RecursiveAstVisitor<void> {
  Rewriter(this.plan, this.unit, {this.self, this.box, this.copyBox});

  final Planner plan;
  final Unit unit;

  /// 'self' in replacement functions, 'this' in extension members, null elsewhere.
  final String? self;

  /// The class whose members are reached through implicit `this` / unqualified statics.
  final Box? box;

  /// When emitting a copied or new class: its own members stay as they are.
  final Box? copyBox;

  final edits = <Edit>[];
  final problems = <String>{};

  String text(AstNode node, {List<Edit> extra = const []}) {
    node.accept(this);
    final all = [...edits, ...extra]
        .map((e) => Edit(e.offset - node.offset, e.end - node.offset, e.text, exclusive: e.exclusive))
        .toList();
    return applyEdits(unit.src.substring(node.offset, node.end), all);
  }

  String part(AstNode? n) {
    if (n == null) return '';
    edits.clear();
    return text(n);
  }

  bool _own(Element? e) {
    if (copyBox == null || e == null) return false;
    var el = e;
    if (el is PropertyAccessorElement) el = el.variable;
    return el.enclosingElement == copyBox!.element;
  }

  String? _key(Element? e) {
    if (e == null) return null;
    var el = e;
    if (el is PropertyAccessorElement) el = el.variable;
    return plan.v2.declKey(el);
  }

  bool _isHostPrivate(String? k) =>
      k != null && k.split('::').last.startsWith('_') && plan.v1Decls.contains(k);

  void _check(Element? e) {
    if (_own(e)) return;
    final pr = plan.problemFor(e);
    if (pr != null) problems.add(pr);
  }

  void _replace(AstNode n, String to, {bool exclusive = false}) {
    final parent = n.parent;
    if (parent is InterpolationExpression && parent.rightBracket == null && to != n.toSource()) {
      edits.add(Edit(parent.offset, parent.end, '\${$to}', exclusive: true));
      return;
    }
    edits.add(Edit(n.offset, n.end, to, exclusive: exclusive));
  }

  Element? _elementOf(SimpleIdentifier n) {
    AstNode target = n;
    final par = n.parent;
    if ((par is PropertyAccess && par.propertyName == n) ||
        (par is PrefixedIdentifier && par.identifier == n)) {
      target = par!;
    }
    final tp = target.parent;
    if (tp is AssignmentExpression && tp.leftHandSide == target) {
      return tp.writeElement ?? tp.readElement ?? n.element;
    }
    if (tp is PrefixExpression && tp.operand == target &&
        (tp.operator.type == TokenType.PLUS_PLUS || tp.operator.type == TokenType.MINUS_MINUS)) {
      return tp.writeElement ?? n.element;
    }
    if (tp is PostfixExpression && tp.operand == target) return tp.writeElement ?? n.element;
    return n.element;
  }

  @override
  void visitThisExpression(ThisExpression node) {
    if (self == 'self' && copyBox == null) _replace(node, 'self');
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final c = node.constructorName.element;
    if (c != null && copyBox == null) {
      final helper = plan.ctorHelpers[plan._ctorKey(c)];
      if (helper != null) {
        edits.add(Edit(node.offset, node.argumentList.offset, helper, exclusive: true));
        node.argumentList.accept(this);
        return;
      }
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final t = node.target;
    if (t is SuperExpression && copyBox == null) {
      _superAccess(t, node.methodName);
      node.typeArguments?.accept(this);
      node.argumentList.accept(this);
      return;
    }
    if (t is SimpleIdentifier && t.element is InterfaceElement && !_own(node.methodName.element)) {
      final to = _staticName(_key(node.methodName.element), node.methodName.name);
      if (to != null) {
        _check(node.methodName.element);
        edits.add(Edit(t.offset, node.methodName.end, to, exclusive: true));
        node.typeArguments?.accept(this);
        node.argumentList.accept(this);
        return;
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final t = node.target;
    if (t is SuperExpression && copyBox == null) {
      _superAccess(t, node.propertyName);
      return;
    }
    super.visitPropertyAccess(node);
  }

  void _superAccess(SuperExpression t, SimpleIdentifier name) {
    final b = box;
    final k = b == null ? null : '${b.unit.rel}::${b.name}::${name.name}';
    if (self == 'self' && k != null && plan.supers.contains(k)) {
      edits.add(Edit(t.offset, name.end, 'self.ota\$super\$${name.name}', exclusive: true));
    } else {
      problems.add('super.${name.name} has no helper in the store build');
    }
  }

  /// Name to use for a static/top-level declaration referenced through its class, if it changes.
  String? _staticName(String? k, String name) {
    if (k == null) return null;
    if (plan.changedConsts.containsKey(k)) return plan.changedConsts[k];
    if (plan.newStatics.containsKey(k)) return plan.newStatics[k];
    if (plan.repointed.containsKey(k)) return plan.repointed[k];
    if (_isHostPrivate(k)) return 'ota\$p\$${k.split('::')[1]}\$$name';
    return null;
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final pe = node.prefix.element;
    final ie = _elementOf(node.identifier);
    if (pe is InterfaceElement && !_own(ie)) {
      final to = _staticName(_key(ie), node.identifier.name);
      if (to != null) {
        _check(ie);
        _replace(node, to, exclusive: true);
        return;
      }
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final e = node.element;
    if (e is InterfaceElement || e is TypeAliasElement) {
      final to = _typeName(e!, node.name.lexeme);
      if (to != null) edits.add(Edit(node.name.offset, node.name.end, to));
      if (!_own(e)) _check(e);
    }
    super.visitNamedType(node);
  }

  String? _typeName(Element e, String name) {
    final k = plan.v2.declKey(e);
    if (k == null) return null;
    final parts = k.split('::');
    final boxKey = '${parts[0]}::${parts[2]}';
    if (plan.copied.containsKey(boxKey)) return plan.copied[boxKey];
    if (_isHostPrivate(k)) return 'ota\$p$name';
    return null;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final par = node.parent;
    if (par is Label || par is CommentReference) return;
    if (par is ConstructorName || par is NamedType) return;
    final e = _elementOf(node);
    if (e == null) return;
    final k = _key(e);
    final explicitTarget = (par is PrefixedIdentifier && par.identifier == node) ||
        (par is PropertyAccess && par.propertyName == node) ||
        (par is MethodInvocation && par.methodName == node && par.target != null);

    if (e is InterfaceElement || e is TypeAliasElement) {
      final to = _typeName(e, node.name);
      if (to != null) _replace(node, to);
      if (!_own(e)) _check(e);
      return;
    }
    if (e is ConstructorElement) {
      final to = _typeName(e.enclosingElement, node.name);
      if (to != null) _replace(node, to);
      return;
    }

    var el = e;
    if (el is PropertyAccessorElement) el = el.variable;
    final encl = el.enclosingElement;
    final isMember = encl is InstanceElement;
    final isStatic = switch (el) {
      ExecutableElement x => x.isStatic,
      VariableElement x => x.isStatic,
      _ => false,
    };

    if (_own(e)) return;
    _check(e);

    if (isMember && !isStatic) {
      var name = node.name;
      if (plan.repointed.containsKey(k)) {
        name = plan.repointed[k]!;
      } else if (_isHostPrivate(k)) {
        name = 'ota\$p${node.name}';
      }
      if (explicitTarget) {
        if (name != node.name) _replace(node, name);
      } else if (self != null) {
        _replace(node, '$self.$name');
      } else if (name != node.name) {
        _replace(node, name);
      }
      return;
    }
    if (isMember && isStatic) {
      if (explicitTarget) return; // handled by the parent
      final to = _staticName(k, node.name);
      if (to != null) {
        _replace(node, to);
      } else if (copyBox == null || encl != copyBox!.element) {
        final cls = encl.name ?? '';
        final clsRef = plan.copied['${k?.split('::').first}::$cls'] ??
            (cls.startsWith('_') ? 'ota\$p$cls' : cls);
        _replace(node, '$clsRef.${node.name}');
      }
      return;
    }
    if (encl is LibraryElement && k != null) {
      if (plan.changedConsts.containsKey(k)) {
        _replace(node, plan.changedConsts[k]!);
      } else if (plan.repointed.containsKey(k)) {
        _replace(node, plan.repointed[k]!);
      } else if (_isHostPrivate(k)) {
        _replace(node, 'ota\$p${node.name}');
      }
    }
  }
}

// ---------------------------------------------------------------------------------- emitter

class PatchEmitter {
  PatchEmitter(this.plan, this.outDir, {this.moduleName});

  final Planner plan;
  final String outDir;

  /// Module mode (device builds): the patch is written as its own package [moduleName] in
  /// [outDir], with an entry point that fills the slots (module entry contract 3). Without it the
  /// patch is written into the instrumented app itself (local simulation).
  final String? moduleName;

  String get _patchDir =>
      moduleName != null ? p.join(outDir, 'lib') : p.join(outDir, 'lib', 'ota_patch');

  /// Where a file that is new in v2 lives, as a package URI.
  String _newUnitUri(String rel) =>
      moduleName != null ? 'package:$moduleName/new/$rel' : 'package:${plan.v2.pkg}/$rel';

  /// Rewrites the imports of v2 source so they work from the patch: relative imports become
  /// package URIs of the store build, except imports of files that are new in v2.
  String _absoluteImport(String fromRel, String uri) {
    final pkg = plan.v2.pkg;
    String? rel;
    if (uri.startsWith('package:$pkg/')) {
      rel = uri.substring('package:$pkg/'.length);
    } else if (!uri.contains(':')) {
      rel = p.posix.normalize(p.posix.join(p.posix.dirname(fromRel), uri));
    }
    if (rel == null) return uri;
    return plan.newUnits.contains(rel) ? _newUnitUri(rel) : 'package:$pkg/$rel';
  }

  final _libs = <String, StringBuffer>{};
  final _installs = <(String, String)>[]; // (slot key, patch unit rel)

  StringBuffer _lib(String rel) => _libs.putIfAbsent(rel, StringBuffer.new);

  static String _patchFile(String rel) =>
      'p_${rel.replaceAll('/', '_').replaceAll('.dart', '')}.dart';

  void emit() {
    if (plan.critical) {
      if (moduleName != null) {
        throw StateError('A whole-app (critical) patch needs SDK support to run the copy\'s own '
            'main; not available in module mode yet.');
      }
      _writeCritical();
      return;
    }
    for (var round = 0; round < 12; round++) {
      _libs.clear();
      _installs.clear();
      for (final l in plan.report.values) {
        l.removeWhere((x) => x.startsWith('patched:'));
      }
      if (_render() == 0) break;
    }
    _write();
  }

  void _drop(String key, String what, Set<String> problems) {
    plan.unavailable.add(key);
    plan.report['dropped']!.add('$what: ${problems.join('; ')}');
  }

  int _render() {
    var dropped = 0;

    for (final key in plan.t1.keys.toList()) {
      final e = plan.v2.exes[key]!;
      final r = _replacement(e);
      if (r.$2.isNotEmpty) {
        plan.t1.remove(key);
        _drop('${e.unit.rel}::${e.box?.name ?? ''}::${e.name}', 'replacement $key', r.$2);
        dropped++;
        continue;
      }
      _lib(e.unit.rel).writeln(r.$1);
      _installs.add((key, e.unit.rel));
    }

    for (final key in plan.inits.keys.toList()) {
      final r = _initReplacement(key);
      if (r == null) continue;
      if (r.$2.isNotEmpty) {
        plan.inits.remove(key);
        _drop(key, 'initializer $key', r.$2);
        dropped++;
        continue;
      }
      _lib(r.$3).writeln(r.$1);
      _installs.add((key, r.$3));
    }

    // re-pointed functions and members: a new version with a new name
    final repointExt = <String, StringBuffer>{};
    for (final entry in {...plan.repointExe}.entries) {
      final e = entry.value;
      final newName = plan.repointed[entry.key]!;
      if (e.isInstance) {
        final rw = Rewriter(plan, e.unit, self: 'this', box: e.box);
        final txt = _memberAs(rw, e, newName);
        if (rw.problems.isNotEmpty) {
          plan.repointExe.remove(entry.key);
          plan.repointed.remove(entry.key);
          _drop(entry.key, 're-pointed ${e.key}', rw.problems);
          dropped++;
          continue;
        }
        repointExt.putIfAbsent('${e.unit.rel}::${e.box!.name}', StringBuffer.new).writeln('  $txt');
      } else {
        final rw = Rewriter(plan, e.unit, box: e.box);
        final rt = e.kind == 'setter' ? 'void ' : (e.returnType == null ? '' : '${rw.part(e.returnType)} ');
        final tps = rw.part(e.typeParams);
        final params = e.kind == 'getter' ? '()' : rw.part(e.params);
        final body = rw.part(e.body);
        if (rw.problems.isNotEmpty) {
          plan.repointExe.remove(entry.key);
          plan.repointed.remove(entry.key);
          _drop(entry.key, 're-pointed ${e.key}', rw.problems);
          dropped++;
          continue;
        }
        _lib(e.unit.rel).writeln('$_pragma\n$rt$newName$tps$params $body');
      }
    }
    for (final entry in repointExt.entries) {
      final box = plan.v2.boxes[entry.key]!;
      _lib(box.unit.rel).writeln(
          'extension ota\$v\$${box.name}${box.tpDecl} on ${_selfType(box, Rewriter(plan, box.unit))} '
          '{\n${entry.value}}');
    }
    for (final entry in {...plan.repointVar}.entries) {
      final (list, v, box) = entry.value;
      final unit = plan.v2.units[entry.key.split('::').first]!;
      final rw = Rewriter(plan, unit, box: box);
      final ty = list.type == null ? '' : '${rw.part(list.type)} ';
      final init = v.initializer == null ? '' : ' = ${rw.part(v.initializer)}';
      if (rw.problems.isNotEmpty) {
        plan.repointVar.remove(entry.key);
        plan.repointed.remove(entry.key);
        _drop(entry.key, 're-pointed variable', rw.problems);
        dropped++;
        continue;
      }
      final kw = list.isConst ? 'const' : (list.isFinal ? 'final' : 'var');
      _lib(unit.rel).writeln('$kw $ty${plan.repointed[entry.key]}$init;');
    }

    // side fields: a side table per field plus accessors on the existing class
    final sideByBox = <String, List<SideField>>{};
    for (final sf in plan.sideFields.values) {
      sideByBox.putIfAbsent('${sf.box.unit.rel}::${sf.box.name}', () => []).add(sf);
    }
    for (final entry in sideByBox.entries) {
      final box = plan.v2.boxes[entry.key]!;
      final buf = StringBuffer();
      final tables = StringBuffer();
      for (final sf in entry.value) {
        final rw = Rewriter(plan, box.unit, box: box);
        final def = sf.v.initializer != null ? rw.part(sf.v.initializer) : sf.defaultSrc;
        tables.writeln('final ${sf.table} = Expando<Object>();');
        buf.writeln('  ${sf.type} get ${sf.name} {\n'
            '    final v = ${sf.table}[this];\n'
            '    if (v != null) return (identical(v, _ota\$null) ? null : v) as ${sf.type};\n'
            '    final ${sf.type} d = $def;\n'
            '    ${sf.table}[this] = d ?? _ota\$null;\n'
            '    return d;\n'
            '  }');
        buf.writeln('  set ${sf.mutable ? sf.name : 'ota\$init_${sf.name}'}(${sf.type} v) => '
            '${sf.table}[this] = v ?? _ota\$null;');
      }
      _lib(box.unit.rel)
        ..write(tables)
        ..writeln('extension ota\$sf\$${box.name} on ${_selfType(box, Rewriter(plan, box.unit))} '
            '{\n$buf}');
    }
    // constructor helpers: old constructor + set the new fields
    for (final entry in plan.ctorHelperDecls.entries) {
      final (box, c1, c2) = entry.value;
      final rw = Rewriter(plan, box.unit, box: box);
      final params = c2.parameters.parameters.map((fp) {
        if (fp is FieldFormalParameter) {
          final sf = plan.sideFields['${box.unit.rel}::${box.name}::${fp.name.lexeme}'];
          final ty = sf?.type ?? 'dynamic';
          final def = fp.defaultClause == null ? '' : ' = ${rw.part(fp.defaultClause!.value)}';
          final req = fp.requiredKeyword == null ? '' : 'required ';
          final isNew = sf != null;
          final oldTy = isNew ? ty : _fieldType(box, fp.name.lexeme);
          return '$req$oldTy ${fp.name.lexeme}$def';
        }
        return rw.part(fp);
      }).toList();
      final req = <String>[], opt = <String>[], named = <String>[];
      final ps = c2.parameters.parameters.toList();
      for (var i = 0; i < ps.length; i++) {
        if (ps[i].isNamed) {
          named.add(params[i]);
        } else if (ps[i].isOptionalPositional) {
          opt.add(params[i]);
        } else {
          req.add(params[i]);
        }
      }
      final sig = [...req, if (opt.isNotEmpty) '[${opt.join(', ')}]',
          if (named.isNotEmpty) '{${named.join(', ')}}'].join(', ');
      final oldArgs = c1.parameters.parameters
          .map((fp) => fp.isNamed ? '${fp.name!.lexeme}: ${fp.name!.lexeme}' : fp.name!.lexeme)
          .join(', ');
      final ctorName = c1.name == null ? '' : '.${c1.name!.lexeme}';
      final cls = box.isPrivate ? 'ota\$p${box.name}' : box.name;
      final sets = ps
          .whereType<FieldFormalParameter>()
          .where((fp) => plan.sideFields.containsKey('${box.unit.rel}::${box.name}::${fp.name.lexeme}'))
          .map((fp) {
        final sf = plan.sideFields['${box.unit.rel}::${box.name}::${fp.name.lexeme}']!;
        return '  o.${sf.mutable ? sf.name : 'ota\$init_${sf.name}'} = ${sf.name};';
      }).join('\n');
      _lib(box.unit.rel).writeln('$_pragma\n$cls ${plan.ctorHelpers[entry.key]}($sig) {\n'
          '  final o = $cls$ctorName($oldArgs);\n$sets\n  return o;\n}');
      plan.report['side_fields']!.add('constructor helper ${entry.key}');
    }

    // new instance members as extension members
    for (final entry in plan.newMembers.entries) {
      final box = plan.v2.boxes[entry.key]!;
      final buf = StringBuffer();
      for (final e in entry.value.toList()) {
        final rw = Rewriter(plan, e.unit, self: 'this', box: box);
        final txt = _memberAs(rw, e, null);
        if (rw.problems.isNotEmpty) {
          entry.value.remove(e);
          _drop('${e.unit.rel}::${box.name}::${e.name}', 'new member ${e.key}', rw.problems);
          dropped++;
          continue;
        }
        buf.writeln('  $txt');
      }
      if (buf.isEmpty) continue;
      _lib(box.unit.rel).writeln(
          'extension ota\$x\$${box.name}${box.tpDecl} on ${_selfType(box, Rewriter(plan, box.unit))} '
          '{\n$buf}');
    }
    // new statics and changed constants
    for (final entry in {...plan.newStatics}.entries) {
      final decl = plan.newStaticDecls[entry.key]!;
      final unit = plan.v2.units[entry.key.split('::').first]!;
      final rw = Rewriter(plan, unit, box: plan.v2.boxes[entry.key.split('::').take(2).join('::')]);
      final String txt;
      if (decl is FieldDeclaration) {
        final v = decl.fields.variables.firstWhere((v) => entry.key.endsWith('::${v.name.lexeme}'));
        final kw = decl.fields.keyword?.lexeme ?? 'var';
        final ty = decl.fields.type == null ? '' : '${rw.part(decl.fields.type)} ';
        final init = v.initializer == null ? '' : ' = ${rw.part(v.initializer)}';
        txt = '$kw $ty${entry.value}$init;';
      } else {
        final m = decl as MethodDeclaration;
        final rt = m.returnType == null ? '' : '${rw.part(m.returnType)} ';
        txt = '$rt${entry.value}${rw.part(m.typeParameters)}${rw.part(m.parameters)} '
            '${rw.part(m.body)}';
      }
      if (rw.problems.isNotEmpty) {
        plan.newStatics.remove(entry.key);
        _drop(entry.key, 'new static ${entry.key}', rw.problems);
        dropped++;
        continue;
      }
      _lib(unit.rel).writeln('$_pragma\n$txt');
    }
    for (final entry in plan.changedConsts.entries) {
      final parts = entry.key.split('::');
      final unit = plan.v2.units[parts[0]]!;
      final rw = Rewriter(plan, unit);
      VariableDeclarationList list;
      VariableDeclaration v;
      if (parts[1].isEmpty) {
        v = plan.v2.topVars['${parts[0]}::${parts[2]}']!;
        list = plan.v2.topVarLists['${parts[0]}::${parts[2]}']!;
      } else {
        final box = plan.v2.boxes['${parts[0]}::${parts[1]}']!;
        final f = box.fields.firstWhere((f) => f.fields.variables.any((x) => x.name.lexeme == parts[2]));
        list = f.fields;
        v = f.fields.variables.firstWhere((x) => x.name.lexeme == parts[2]);
      }
      final ty = list.type == null ? '' : '${list.type!.toSource()} ';
      _lib(unit.rel).writeln('const $ty${entry.value} = ${rw.part(v.initializer)};');
    }
    // new top-level declarations
    for (final entry in {...plan.newTop}.entries) {
      final rel = entry.key.split('::').first;
      final unit = plan.v2.units[rel]!;
      final box = plan.v2.boxes[entry.key];
      final rw = Rewriter(plan, unit, copyBox: box, box: box);
      final txt = rw.text(entry.value);
      if (rw.problems.isNotEmpty) {
        plan.newTop.remove(entry.key);
        _drop(entry.key.replaceFirst('::', '::::'), 'new declaration ${entry.key}', rw.problems);
        dropped++;
        continue;
      }
      _lib(rel).writeln(txt);
    }
    // class copies
    for (final entry in {...plan.copied}.entries) {
      final box = plan.v2.boxes[entry.key]!;
      final rw = Rewriter(plan, box.unit, copyBox: box, box: box);
      final tok = box.nameToken!;
      final txt = rw.text(box.node, extra: [Edit(tok.offset, tok.end, entry.value)]);
      if (rw.problems.isNotEmpty) {
        plan.copied.remove(entry.key);
        _drop(entry.key.replaceFirst('::', '::::'), 'class copy ${entry.key}', rw.problems);
        dropped++;
        continue;
      }
      _lib(box.unit.rel).writeln(txt);
    }
    return dropped;
  }

  String _fieldType(Box box, String name) {
    for (final f in box.fields) {
      for (final v in f.fields.variables) {
        if (v.name.lexeme == name) {
          return f.fields.type?.toSource() ??
              (v.declaredFragment?.element.type.getDisplayString() ?? 'dynamic');
        }
      }
    }
    return 'dynamic';
  }

  /// A member's source as an extension member, optionally renamed.
  String _memberAs(Rewriter rw, Exe e, String? newName) {
    final m = e.node as MethodDeclaration;
    final start = m.firstTokenAfterCommentAndMetadata.offset;
    final extra = <Edit>[
      if (newName != null) Edit(m.name.offset, m.name.end, newName),
      if (m.modifierKeyword != null) Edit(m.modifierKeyword!.offset, m.modifierKeyword!.end, ''),
    ];
    rw.edits.clear();
    final full = rw.text(m, extra: extra);
    return full.substring(start - m.offset);
  }

  String _selfType(Box box, Rewriter rw) {
    if (box.node is ExtensionDeclaration) {
      return rw.part((box.node as ExtensionDeclaration).onClause!.extendedType);
    }
    final n = box.isPrivate ? 'ota\$p${box.name}' : box.name;
    return '$n${box.tpNames}';
  }

  (String, Set<String>) _replacement(Exe e) {
    final rw = Rewriter(plan, e.unit, self: e.isInstance ? 'self' : null, box: e.box);
    final rt =
        e.kind == 'setter' ? 'void ' : (e.returnType == null ? '' : '${rw.part(e.returnType)} ');
    final tps = [
      if (e.isInstance && e.box?.typeParams != null)
        ...e.box!.typeParams!.typeParameters.map(rw.part),
      if (e.typeParams != null) ...e.typeParams!.typeParameters.map(rw.part),
    ];
    final tpDecl = tps.isEmpty ? '' : '<${tps.join(', ')}>';
    var params = e.params == null ? '()' : rw.part(e.params);
    if (e.isInstance) {
      final selfParam = '${_selfType(e.box!, Rewriter(plan, e.unit))} self';
      final inner = params.substring(1, params.length - 1).trim();
      params = '($selfParam${inner.isEmpty ? '' : ', $inner'})';
    }
    final body = rw.part(e.body);
    plan.report['patched']!.add('${e.key} [${plan.t1[e.key]}]');
    return ('$_pragma\n$rt${e.replacement}$tpDecl$params $body', rw.problems);
  }

  /// Replacement for an initializer slot: `T ota$r..([Self self]) => <new initializer>`.
  (String, Set<String>, String)? _initReplacement(String key) {
    final info = plan.slots[key] as Map;
    final declKey = key.substring(0, key.length - '::init'.length);
    final parts = declKey.split('::');
    VariableDeclaration? v;
    Box? box;
    if (parts[1].isEmpty) {
      v = plan.v2.topVars['${parts[0]}::${parts[2]}'];
    } else {
      box = plan.v2.boxes['${parts[0]}::${parts[1]}'];
      for (final f in box?.fields ?? const <FieldDeclaration>[]) {
        for (final x in f.fields.variables) {
          if (x.name.lexeme == parts[2]) v = x;
        }
      }
    }
    if (v?.initializer == null) return null;
    final unit = plan.v2.units[parts[0]]!;
    final withSelf = info['self'] == true;
    final rw = Rewriter(plan, unit, self: withSelf ? 'self' : null, box: box);
    final init = rw.part(v!.initializer);
    final selfParam = withSelf ? '${_selfType(box!, Rewriter(plan, unit))} self' : '';
    plan.report['initializers']!.add('$declKey [${plan.inits[key]}]');
    return (
      '$_pragma\n${info['type']} ${info['replacement']}($selfParam) => $init;',
      rw.problems,
      unit.rel,
    );
  }

  void _writeLib(String rel, String body, Map<String, String> files) {
    final pkg = plan.v2.pkg;
    final unit = plan.v2.units[rel]!;
    final imports = StringBuffer()
      ..writeln('// GENERATED by ota_redirect patch from $rel. Do not edit.')
      ..writeln('// ignore_for_file: type=lint, unused_import, unused_element')
      ..writeln("import 'package:$pkg/$rel';");
    for (final d in unit.ast.directives.whereType<ImportDirective>()) {
      final abs = _absoluteImport(rel, d.uri.stringValue!);
      imports.writeln(d.toSource().replaceFirst(d.uri.toSource(), "'$abs'"));
    }
    for (final other in files.values) {
      if (other != files[rel]) imports.writeln("import '$other';");
    }
    imports.writeln('const _ota\$null = Object();');
    File(p.join(_patchDir, files[rel]!)).writeAsStringSync('$imports\n$body');
  }

  void _write() {
    final patchDir = _patchDir;
    Directory(patchDir).createSync(recursive: true);
    final pkg = plan.v2.pkg;
    final files = {for (final rel in _libs.keys) rel: _patchFile(rel)};
    for (final entry in _libs.entries) {
      _writeLib(entry.key, entry.value.toString(), files);
    }
    for (final rel in plan.newUnits) {
      final unit = plan.v2.units[rel]!;
      final dest = File(moduleName != null
          ? p.join(outDir, 'lib', 'new', rel)
          : p.join(outDir, 'lib', rel));
      dest.parent.createSync(recursive: true);
      var src = unit.src;
      if (moduleName != null) {
        final edits = [
          for (final d in unit.ast.directives.whereType<UriBasedDirective>())
            if (d.uri.stringValue != null)
              Edit(d.uri.offset, d.uri.end, "'${_absoluteImport(rel, d.uri.stringValue!)}'"),
        ];
        src = applyEdits(src, edits);
      }
      dest.writeAsStringSync(src);
    }
    final inst = StringBuffer()
      ..writeln("// GENERATED by ota_redirect patch. Fills the store build's slots.")
      ..writeln('// ignore_for_file: type=lint');
    final hostAlias = <String, String>{};
    final patchAlias = <String, String>{};
    for (final (key, rel) in _installs) {
      final slotUnit = (plan.slots[key] as Map)['unit'] as String;
      hostAlias.putIfAbsent(slotUnit, () => 'h${hostAlias.length}');
      patchAlias.putIfAbsent(rel, () => 'p${patchAlias.length}');
    }
    hostAlias.forEach((rel, a) => inst.writeln("import 'package:$pkg/$rel' as $a;"));
    patchAlias.forEach((rel, a) => inst.writeln("import '${files[rel]}' as $a;"));
    inst.writeln('\n/// Set only by a whole-app (critical) patch.');
    inst.writeln('Future<void> Function(List<String>)? otaMain;');
    inst.writeln('\nvoid otaInstall() {');
    for (final (key, rel) in _installs) {
      final s = plan.slots[key] as Map;
      inst.writeln('  ${hostAlias[s['unit']]}.${s['slot']} = ${patchAlias[rel]}.${s['replacement']};');
    }
    inst.writeln('}');
    File(p.join(patchDir, 'install.dart')).writeAsStringSync(inst.toString());
    if (moduleName != null) _writeModulePackage();
    _writeReport();
  }

  /// Module mode: package metadata and the entry point the SDK calls when it loads the module.
  void _writeModulePackage() {
    File(p.join(outDir, 'pubspec.yaml')).writeAsStringSync(
        '# GENERATED by ota_redirect patch. Bytecode patch module.\n'
        'name: $moduleName\npublish_to: none\nversion: 1.0.0\n'
        'environment:\n  sdk: ^3.8.0\n');
    File(p.join(outDir, 'lib', 'entry.dart')).writeAsStringSync(
        '// GENERATED by ota_redirect patch. Module entry (contract 3): fills the slots of the\n'
        '// store build when the module is loaded, before the app starts. No feature slots.\n'
        "import 'dart:typed_data';\n\nimport 'install.dart';\n\n"
        "@pragma('dyn-module:entry-point')\n"
        'Object? otaPatchEntry() {\n'
        '  otaInstall();\n'
        "  return <String, Object?>{\n    'contract': 3,\n"
        "    'features': <String, Object? Function()>{},\n"
        "    'assets': <String, Uint8List>{},\n  };\n}\n");
  }

  /// Level 4: the whole app ships as a renamed copy and its own `main` runs instead.
  void _writeCritical() {
    final pkg = plan.v2.pkg;
    final full = p.join(outDir, 'lib', 'ota_full');
    String rewrite(String src) => src.replaceAll("'package:$pkg/", "'package:$pkg/ota_full/");
    for (final entry in plan.v2.units.entries) {
      final dest = File(p.join(full, entry.key));
      dest.parent.createSync(recursive: true);
      dest.writeAsStringSync(rewrite(entry.value.src));
    }
    final entry = File(p.join(plan.v2.dir, 'bin', 'main.dart')).readAsStringSync();
    File(p.join(full, 'ota_entry.dart')).writeAsStringSync(rewrite(entry));
    final patchDir = p.join(outDir, 'lib', 'ota_patch');
    Directory(patchDir).createSync(recursive: true);
    File(p.join(patchDir, 'install.dart')).writeAsStringSync(
        "// GENERATED by ota_redirect patch (critical: whole-app copy).\n"
        "import 'package:$pkg/ota_full/ota_entry.dart' as full;\n\n"
        'Future<void> Function(List<String>)? otaMain = full.main;\n\n'
        'void otaInstall() {}\n');
    plan.report['added']!.add('whole app copied to lib/ota_full (${plan.v2.units.length} files)');
    _writeReport();
  }

  void _writeReport() {
    final m = plan.metrics();
    plan.report['level'] = ['${m['level']}'];
    final out = {'metrics': m, ...plan.report.map((k, v) => MapEntry(k, v.toSet().toList()))};
    File(p.join(outDir, 'ota_patch_report.json'))
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  }
}
