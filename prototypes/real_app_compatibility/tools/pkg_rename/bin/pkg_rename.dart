// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 2 prototype: Dart-aware package renaming for bytecode modules. NOT the production patch
// generator.
//
// Run with the pinned Dart SDK checkout's package config (it provides package:analyzer/yaml):
//   dart --packages=<dart-src>/.dart_tool/package_config.json pkg_rename.dart <command> ...
//
// Commands:
//   graph   --packages-root DIR --host-lock pubspec.lock --pub-cache DIR --policy policy.yaml
//   prepare --module DIR --packages-root DIR --host-lock pubspec.lock --pub-cache DIR
//           --policy policy.yaml --out DIR
//
// prepare copies every package listed in the module's module.yaml (`change:` internal packages,
// `external:` third-party packages at a given version) to <name>_<suffix>, applies the module's
// overlay files, and rewrites package URIs ONLY in import/export/part/part-of directives and
// conditional-import configurations, using the analyzer's parser (never a text search/replace).

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:yaml/yaml.dart';

Never fail(String message) {
  stderr.writeln('pkg_rename: $message');
  exit(2);
}

Map<String, String> parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) fail('unexpected argument ${args[i]}');
    if (i + 1 >= args.length) fail('missing value for ${args[i]}');
    out[args[i].substring(2)] = args[++i];
  }
  return out;
}

class Pkg {
  Pkg(this.name, this.dir, this.pubspec);
  final String name;
  final Directory dir;
  final YamlMap pubspec;
  Iterable<String> get deps => ((pubspec['dependencies'] as YamlMap?) ?? YamlMap()).keys.cast<String>();
}

Pkg readPkg(Directory dir) {
  final pubspec = loadYaml(File('${dir.path}/pubspec.yaml').readAsStringSync()) as YamlMap;
  return Pkg(pubspec['name'] as String, dir, pubspec);
}

Map<String, Pkg> internalPackages(String root) => {
      for (final d in Directory(root).listSync().whereType<Directory>())
        if (File('${d.path}/pubspec.yaml').existsSync()) readPkg(d).name: readPkg(d),
    };

/// Hosted packages from the host's lock file: name -> exact version.
Map<String, String> hostedLock(String lockPath) {
  final lock = loadYaml(File(lockPath).readAsStringSync()) as YamlMap;
  final out = <String, String>{};
  (lock['packages'] as YamlMap).forEach((k, v) {
    if ((v as YamlMap)['source'] == 'hosted') out[k as String] = v['version'] as String;
  });
  return out;
}

Directory pubCachePackage(String pubCache, String name, String version) {
  final d = Directory('$pubCache/hosted/pub.dev/$name-$version');
  if (!d.existsSync()) fail('$name $version is not in the pub cache (${d.path})');
  return d;
}

// --- classification -----------------------------------------------------------------------------

/// PATCHABLE / PATCHABLE_WITH_RESTRICTIONS / NOT_PATCHABLE / REQUIRES_FULL_RELEASE, with reasons.
(String, List<String>) classify(Pkg p, YamlMap policy) {
  final reasons = <String>[];
  if ((policy['sdk_packages'] as YamlList).contains(p.name)) {
    return ('REQUIRES_FULL_RELEASE', ['SDK package: changes mean a new Flutter version and a new baseline']);
  }
  if (((policy['host_runtime'] as YamlList?) ?? YamlList()).contains(p.name)) {
    return ('REQUIRES_FULL_RELEASE', ['patch runtime (module loader) of the host']);
  }
  if ((policy['host_owned'] as YamlList).contains(p.name)) {
    return ('REQUIRES_FULL_RELEASE', ['host-owned contract/model/state package: a copy has new class identities and separate state']);
  }
  final flutter = p.pubspec['flutter'];
  final isPlugin = flutter is YamlMap && flutter['plugin'] != null;
  final native = ['android', 'ios', 'linux', 'macos', 'windows', 'src', 'cpp']
      .where((d) => Directory('${p.dir.path}/$d').existsSync())
      .toList();
  var ffi = false;
  var webOnly = false;
  final lib = Directory('${p.dir.path}/lib');
  if (lib.existsSync()) {
    for (final f in lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final unit = parseString(content: f.readAsStringSync(), throwIfDiagnostics: false).unit;
      for (final d in unit.directives.whereType<NamespaceDirective>()) {
        final u = d.uri.stringValue;
        if (u == 'dart:ffi') ffi = true;
        if (d is ImportDirective && d.configurations.isEmpty && (u == 'dart:js_interop' || u == 'dart:ui_web' || u == 'dart:html')) {
          webOnly = true;
        }
      }
    }
  }
  if (webOnly) {
    return ('NOT_PATCHABLE', ['web-only package (unconditional dart:js_interop/ui_web/html import): not compiled for Android']);
  }
  if (ffi) {
    return ('NOT_PATCHABLE', ['imports dart:ffi (FFI calls are not supported in interpreted bytecode; see Phase 2 FFI probe)']);
  }
  if (isPlugin || native.isNotEmpty) {
    reasons.add('Flutter plugin / native code (${[if (isPlugin) 'flutter.plugin', ...native].join(', ')}): '
        'only the Dart side can change, the platform channel API must stay the same; native changes need a full release');
  }
  final assets = flutter is YamlMap && (flutter['assets'] != null || flutter['fonts'] != null);
  if (assets) reasons.add('declares assets/fonts: a module carries no assets (use the host overlay bundle)');
  return (reasons.isEmpty ? 'PATCHABLE' : 'PATCHABLE_WITH_RESTRICTIONS', reasons.isEmpty ? ['pure Dart'] : reasons);
}

// --- rewriting -------------------------------------------------------------------------------------

class RewriteStats {
  final counts = <String, int>{};
  final warnings = <String>[];
  int files = 0;
  void add(String kind) => counts[kind] = (counts[kind] ?? 0) + 1;
  Map<String, Object?> toJson() => {'files': files, 'rewritten_uris': counts, 'warnings': warnings};
}

/// Rewrites `package:<old>/...` to `package:<new>/...` in directive URIs only.
String rewriteDart(String source, Map<String, String> renames, String path, RewriteStats stats) {
  final unit = parseString(content: source, path: path, throwIfDiagnostics: false).unit;
  final edits = <(int, int, String)>[];

  void visit(StringLiteral? lit, String kind) {
    if (lit is! SimpleStringLiteral) return;
    final uri = lit.value;
    if (!uri.startsWith('package:')) return;
    final name = uri.substring(8).split('/').first;
    final renamed = renames[name];
    if (renamed == null) return;
    final quote = lit.literal.lexeme.startsWith('"') ? '"' : "'";
    edits.add((lit.offset, lit.end, '$quote${uri.replaceFirst('package:$name/', 'package:$renamed/')}$quote'));
    stats.add(kind);
  }

  for (final d in unit.directives) {
    // `// pkg_rename:keep` directly above a directive keeps the HOST package (explicit reference to
    // the original, e.g. to compare AOT and interpreted code).
    Token? comment = d.beginToken.precedingComments;
    var keep = false;
    while (comment != null) {
      if (comment.lexeme.contains('pkg_rename:keep')) keep = true;
      comment = comment.next;
    }
    if (keep) {
      stats.add('kept_host_reference');
      continue;
    }
    switch (d) {
      case ImportDirective():
        visit(d.uri, 'import');
        for (final c in d.configurations) {
          visit(c.uri, 'conditional_import');
        }
      case ExportDirective():
        visit(d.uri, 'export');
        for (final c in d.configurations) {
          visit(c.uri, 'conditional_export');
        }
      case PartDirective():
        visit(d.uri, 'part');
      case PartOfDirective():
        visit(d.uri, 'part_of');
      default:
        break;
    }
  }
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  var out = source;
  for (final (start, end, text) in edits) {
    out = out.replaceRange(start, end, text);
  }
  // Anything left that mentions an old package URI is outside a directive (a string or comment):
  // reported, never rewritten.
  for (final old in renames.keys) {
    if (out.contains('package:$old/')) stats.warnings.add('$path: "package:$old/" left outside directives');
    if (out.contains("'packages/$old/") || out.contains('"packages/$old/')) {
      stats.warnings.add('$path: asset key "packages/$old/..." still points at the ORIGINAL package assets');
    }
  }
  stats.files++;
  return out;
}

String yamlScalar(Object? v) => v is String ? jsonEncode(v) : '$v';

/// Writes a pubspec for a copied/renamed package. Dependencies resolve exactly as in the host:
/// renamed packages by path, internal originals by path, hosted packages pinned to the host lock.
String rewritePubspec(Pkg p, String newName, Map<String, String> renames, Map<String, Pkg> internal,
    Map<String, String> lock, String outRoot, {bool keepOriginals = false}) {
  final b = StringBuffer()
    ..writeln('# Generated by pkg_rename from ${p.name} - do not edit.')
    ..writeln('name: $newName')
    ..writeln('publish_to: none')
    ..writeln('version: ${p.pubspec['version'] ?? '0.0.0'}')
    ..writeln('environment:');
  ((p.pubspec['environment'] as YamlMap?) ?? YamlMap()).forEach((k, v) => b.writeln('  $k: ${yamlScalar(v)}'));
  b.writeln('dependencies:');
  final deps = (p.pubspec['dependencies'] as YamlMap?) ?? YamlMap();
  deps.forEach((k, v) {
    final name = k as String;
    if (renames.containsKey(name)) {
      b.writeln('  ${renames[name]}:\n    path: $outRoot/${renames[name]}');
      if (keepOriginals && internal.containsKey(name)) b.writeln('  $name:\n    path: ${internal[name]!.dir.absolute.path}');
      if (keepOriginals && lock.containsKey(name)) b.writeln('  $name: ${lock[name]}');
    } else if (internal.containsKey(name)) {
      b.writeln('  $name:\n    path: ${internal[name]!.dir.absolute.path}');
    } else if (v is YamlMap && v['sdk'] != null) {
      b.writeln('  $name:\n    sdk: ${v['sdk']}');
    } else if (lock.containsKey(name)) {
      b.writeln('  $name: ${lock[name]}');
    } else {
      b.writeln('  $name: ${yamlScalar(v ?? 'any')}');
    }
  });
  // Pin the whole graph to the host's resolution (a module must link against the host's code).
  b.writeln('dependency_overrides:');
  lock.forEach((name, version) {
    if (!renames.containsKey(name) || keepOriginals) b.writeln('  $name: $version');
  });
  internal.forEach((name, pkg) {
    if (!renames.containsKey(name) || keepOriginals) b.writeln('  $name:\n    path: ${pkg.dir.absolute.path}');
  });
  return b.toString();
}

void copyTree(Directory from, Directory to, {required bool Function(String rel) include}) {
  for (final e in from.listSync(recursive: true).whereType<File>()) {
    final rel = e.path.substring(from.path.length + 1);
    if (!include(rel)) continue;
    final target = File('${to.path}/$rel');
    target.parent.createSync(recursive: true);
    e.copySync(target.path);
  }
}

// --- commands ------------------------------------------------------------------------------------

void graph(Map<String, String> a) {
  final internal = internalPackages(a['packages-root']!);
  final policy = loadYaml(File(a['policy']!).readAsStringSync()) as YamlMap;
  final lock = hostedLock(a['host-lock']!);
  final out = <String, Object?>{};
  for (final p in internal.values) {
    final (cls, why) = classify(p, policy);
    out[p.name] = {
      'kind': 'internal',
      'deps': p.deps.toList()..sort(),
      'used_by': [for (final q in internal.values) if (q.deps.contains(p.name)) q.name]..sort(),
      'class': cls,
      'reasons': why,
    };
  }
  for (final MapEntry(key: name, value: version) in lock.entries) {
    final p = readPkg(pubCachePackage(a['pub-cache']!, name, version));
    final (cls, why) = classify(p, policy);
    out[name] = {'kind': 'hosted', 'version': version, 'class': cls, 'reasons': why};
  }
  for (final s in policy['sdk_packages'] as YamlList) {
    out['$s'] = {'kind': 'sdk', 'class': 'REQUIRES_FULL_RELEASE', 'reasons': ['SDK package']};
  }
  print(const JsonEncoder.withIndent('  ').convert(out));
}

void prepare(Map<String, String> a) {
  final moduleDir = Directory(a['module']!).absolute;
  final spec = loadYaml(File('${moduleDir.path}/module.yaml').readAsStringSync()) as YamlMap;
  final internal = internalPackages(a['packages-root']!);
  final policy = loadYaml(File(a['policy']!).readAsStringSync()) as YamlMap;
  final lock = hostedLock(a['host-lock']!);
  final outRoot = Directory(a['out']!).absolute;
  final suffix = spec['suffix'] as String;
  final change = ((spec['change'] as YamlList?) ?? YamlList()).cast<String>().toList();
  final external = ((spec['external'] as YamlMap?) ?? YamlMap()).cast<String, Object?>();
  final allowStale = spec['allow_stale'] == true;
  final allowHostOwned = spec['allow_host_owned'] == true;

  final errors = <String>[];
  final notes = <String>[];
  for (final c in change) {
    final p = internal[c] ?? fail('unknown internal package $c');
    final (cls, why) = classify(p, policy);
    if (cls == 'REQUIRES_FULL_RELEASE' || cls == 'NOT_PATCHABLE') {
      (allowHostOwned ? notes : errors).add('$c is $cls: ${why.join('; ')}');
    } else if (cls == 'PATCHABLE_WITH_RESTRICTIONS') {
      notes.add('$c is $cls: ${why.join('; ')}');
    }
  }
  for (final MapEntry(key: name, value: version) in external.entries) {
    final p = readPkg(pubCachePackage(a['pub-cache']!, name, '$version'));
    final (cls, why) = classify(p, policy);
    notes.add('external $name ${lock[name] ?? '?'} -> $version: $cls (${why.join('; ')})');
    if (cls == 'NOT_PATCHABLE' || cls == 'REQUIRES_FULL_RELEASE') errors.add('external $name is $cls');
  }

  // Closure check: an UNCHANGED package the module reaches that (transitively) depends on a changed
  // package would keep calling the OLD code from the host. It must be included in `change`.
  final changed = {...change, ...external.keys};
  final module = readPkg(moduleDir);
  final reachesChanged = <String, bool>{};
  bool reaches(String n, Set<String> seen) {
    if (reachesChanged.containsKey(n)) return reachesChanged[n]!;
    if (!seen.add(n)) return false;
    final p = internal[n];
    final r = p != null && p.deps.any((d) => changed.contains(d) || (!changed.contains(d) && reaches(d, seen)));
    return reachesChanged[n] = r;
  }

  final visited = <String>{};
  void walk(Iterable<String> deps) {
    for (final d in deps) {
      if (!visited.add(d)) continue;
      if (changed.contains(d)) {
        if (internal[d] != null) walk(internal[d]!.deps);
      } else if (internal[d] != null) {
        if (reaches(d, {})) {
          errors.add('stale dependency: unchanged package "$d" (reached by the module) depends on a changed '
              'package; include "$d" in `change`');
        }
        walk(internal[d]!.deps);
      }
    }
  }

  walk(module.deps);
  if (errors.isNotEmpty && allowStale && errors.every((e) => e.startsWith('stale'))) {
    notes.addAll(errors.map((e) => 'IGNORED (allow_stale experiment): $e'));
    errors.clear();
  }
  if (errors.isNotEmpty) {
    stderr.writeln('pkg_rename: REFUSED to build ${module.name}:');
    for (final e in errors) {
      stderr.writeln('  - $e');
    }
    exit(3);
  }

  final renames = {for (final n in changed) n: '${n}_$suffix'};
  if (outRoot.existsSync()) outRoot.deleteSync(recursive: true);
  outRoot.createSync(recursive: true);
  final stats = RewriteStats();
  final report = <String, Object?>{'module': module.name, 'renames': renames, 'notes': notes};

  void emit(Pkg p, String newName, Directory? overlay, {bool keepOriginals = false}) {
    final dest = Directory('${outRoot.path}/$newName')..createSync(recursive: true);
    copyTree(p.dir, dest, include: (rel) => rel.startsWith('lib/'));
    if (overlay != null && overlay.existsSync()) {
      copyTree(overlay, dest, include: (rel) => rel.startsWith('lib/'));
    }
    for (final f in Directory('${dest.path}/lib').listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.dart')) {
        f.writeAsStringSync(rewriteDart(f.readAsStringSync(), renames, f.path.substring(outRoot.path.length + 1), stats));
      }
    }
    File('${dest.path}/pubspec.yaml').writeAsStringSync(rewritePubspec(p, newName, renames, internal, lock, outRoot.path, keepOriginals: keepOriginals));
  }

  for (final c in change) {
    emit(internal[c]!, renames[c]!, Directory('${moduleDir.path}/overlay/$c'));
  }
  for (final MapEntry(key: name, value: version) in external.entries) {
    emit(readPkg(pubCachePackage(a['pub-cache']!, name, '$version')), renames[name]!,
        Directory('${moduleDir.path}/overlay/$name'));
  }
  emit(module, module.name, null, keepOriginals: true);
  report['rewrite'] = stats.toJson();
  File('${outRoot.path}/rename_report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  print(const JsonEncoder.withIndent('  ').convert(report));
}

void main(List<String> args) {
  if (args.isEmpty) fail('usage: pkg_rename.dart graph|prepare --option value ...');
  final a = parseArgs(args.sublist(1));
  switch (args.first) {
    case 'graph':
      graph(a);
    case 'prepare':
      prepare(a);
    default:
      fail('unknown command ${args.first}');
  }
}
