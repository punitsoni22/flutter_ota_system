// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../context.dart';
import '../errors.dart';
import '../project/project.dart';
import 'discovery.dart';
import 'generator.dart';
import 'package_graph.dart';

String _projectDir(CliContext ctx) {
  final d = findProjectDir(ctx.workingDirectory);
  if (d == null) throw CliException('No $projectFileName found. Run `flutter_ota init` in your app first.');
  return d;
}

/// `flutter_ota features` shows the feature graph; `flutter_ota features generate` writes the
/// registry. (`generate` is a positional action: a command with sub-commands cannot also run
/// on its own in package:args.)
class FeaturesCommand extends Command<int> {
  FeaturesCommand(this.ctx) {
    argParser
      ..addFlag('json', negatable: false, help: 'Print the graph as JSON.')
      ..addFlag(
        'check',
        negatable: false,
        help: 'With generate: only check that the generated files are up to date (exit 1 if not).',
      );
  }

  final CliContext ctx;

  @override
  String get name => 'features';
  @override
  String get description =>
      'Show the patchable features, the shared packages and their dependency graph. '
      '`features generate` writes lib/$registryFileName (one typed slot per feature).';
  @override
  String get invocation => 'flutter_ota features [generate [--check]] [--json]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) return _show();
    if (rest.length == 1 && rest.single == 'generate') return _generate();
    usageException(
      'Unknown action "${rest.join(' ')}". Use `flutter_ota features` or `flutter_ota features generate`.',
    );
  }

  int _show() {
    final graph = FeatureGraph.build(ProjectPackages.load(_projectDir(ctx)));
    if (argResults!['json'] == true) {
      ctx.out.writeln(const JsonEncoder.withIndent('  ').convert(graph.toJson()));
    } else {
      ctx.out.write(describeGraph(graph));
    }
    return graph.problems.isEmpty ? 0 : 1;
  }

  int _generate() {
    final dir = _projectDir(ctx);
    final check = argResults!['check'] == true;
    final r = generateFeatureRegistry(dir, check: check);
    for (final w in r.graph.warnings) {
      ctx.log('warning: $w');
    }
    final rel = p.relative(r.path, from: dir);
    final entryRel = r.entryPath == null ? null : p.relative(r.entryPath!, from: dir);
    if (check) {
      final stale = [if (r.changed) rel, if (r.entryChanged) entryRel!];
      ctx.out.writeln(
        stale.isNotEmpty
            ? 'Generated files are OUT OF DATE (${stale.join(', ')}). Run: flutter_ota features generate'
            : '$rel is up to date.',
      );
      return stale.isNotEmpty ? 1 : 0;
    }
    if (r.entryChanged) ctx.out.writeln('Rewrote $entryRel (it differed from what the release command writes).');
    if (r.graph.features.isEmpty && !r.changed) {
      ctx.out.writeln('No feature packages found, nothing generated. See docs/feature-patching.md.');
      return 0;
    }
    ctx.out.writeln(
      r.changed ? 'Wrote $rel (${r.graph.features.length} feature slot(s)).' : '$rel is already up to date.',
    );
    return 0;
  }
}

/// Human-readable graph for `flutter_ota features`.
String describeGraph(FeatureGraph g) {
  final b = StringBuffer();
  final app = g.project.app;
  b.writeln('App: ${app.name} (never patchable: compiled into the store build)');
  b.writeln();
  b.writeln('Features (patchable, one slot each):');
  if (g.features.isEmpty) b.writeln('  (none: see docs/feature-patching.md for the convention)');
  for (final f in g.packagesWithRole(PackageRole.feature)) {
    final e = g.features[f]!;
    b.writeln('  $f  ${g.project.local[f]!.relativeDir}');
    b.writeln(
      '    entry ${e.className} (${e.declaredIn}) -> OtaFeatures.${e.getter} : ${e.contractType} '
      'from ${e.contractPackage}',
    );
    final unit = g.unitOf(f).skip(1).toList();
    if (unit.isNotEmpty) b.writeln('    patched together with: ${unit.join(', ')}');
  }
  b.writeln();
  b.writeln('Shared packages (host-owned; a change needs a new store release):');
  final shared = [...g.packagesWithRole(PackageRole.shared), ...g.project.outsideProject, ...g.project.toolOwned];
  if (shared.isEmpty) b.writeln('  (none)');
  for (final s in shared) {
    b.writeln('  $s  ${(g.reasons[s] ?? const []).join('; ')}');
  }
  b.writeln();
  b.writeln('Dependency graph (local packages):');
  for (final n in [app.name, ...(g.project.local.keys.toList()..sort())]) {
    final deps = g.localDepsOf(n).toList()..sort();
    b.writeln('  $n [${roleLabel(g.roles[n]!)}]${deps.isEmpty ? '' : ' -> ${deps.join(', ')}'}');
  }
  if (g.warnings.isNotEmpty) {
    b.writeln();
    b.writeln('Warnings:');
    for (final w in g.warnings) {
      b.writeln('  - $w');
    }
  }
  if (g.problems.isNotEmpty) {
    b.writeln();
    b.writeln('Problems (fix these before generating or patching):');
    for (final x in g.problems) {
      b.writeln('  - $x');
    }
  }
  return b.toString();
}
