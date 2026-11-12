// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Decides what a patch contains, or why it cannot be made.
//
// Closure rule: a patch carries every changed feature (or feature-internal) package plus every
// feature or feature-internal package that depends on one of them, transitively. An unchanged
// package that depends on a changed one would otherwise keep calling the OLD code of the store
// build. Each patched package is copied and renamed, so it gets new types and new state.
//
// Refused (needs a new store release): changes to the app package, to shared (host-owned)
// packages, to native code, assets or the pubspec `flutter:` section, to pubspec.lock, to the
// generated registry, new or removed packages, and new dependencies the store build lacks.

import '../features/discovery.dart';
import '../features/snapshot.dart';
import '../toolchain/canonical_json.dart';

class PatchPlan {
  PatchPlan(this.graph, this.diff);
  final FeatureGraph graph;
  final SnapshotDiff diff;

  /// Reasons the patch cannot be made (each needs a new store release or a fix).
  final refusals = <String>[];
  final notes = <String>[];

  /// Packages with changed sources (feature or feature-internal).
  final changed = <String>{};

  /// Packages compiled (renamed) into the patch: [changed] plus their dependents (closure).
  final packages = <String>{};

  /// Why each package of [packages] is included.
  final why = <String, String>{};

  /// Features whose slots the patch fills.
  List<String> get features => (packages.where((n) => graph.roles[n] == PackageRole.feature).toList()..sort());

  bool get isEmpty => refusals.isEmpty && packages.isEmpty;
}

const _storeRelease = 'needs a new store release';

/// Plans a patch from the current [graph] and the [diff] against the release snapshot.
/// [hostPackages] are the packages of the store build.
PatchPlan planPatch(FeatureGraph graph, SnapshotDiff diff, Set<String> hostPackages) {
  final plan = PatchPlan(graph, diff);
  final refuse = plan.refusals.add;
  for (final pr in graph.problems) {
    refuse('feature setup: $pr');
  }
  if (diff.lockChanged) {
    refuse(
      'pubspec.lock changed since the release: the store build was made with other dependency '
      'versions ($_storeRelease). Restore the lock file of the release, or make a new store release.',
    );
  }
  if (diff.registryChanged) {
    refuse(
      'lib/$registryFileName changed since the release (features added, removed or renamed): '
      'the store build has other slots ($_storeRelease).',
    );
  }
  for (final c in diff.changed.toList()..sort((a, b) => a.name.compareTo(b.name))) {
    final name = c.name;
    final releaseRole = diff.releaseRole(name);
    final role = graph.roles[name];
    if (c.added) {
      refuse('$name is a new package that is not in the store build ($_storeRelease).');
      continue;
    }
    if (c.removed) {
      refuse('$name was removed since the release ($_storeRelease).');
      continue;
    }
    if (releaseRole == PackageRole.app.name || role == PackageRole.app) {
      refuse(
        'the app package $name changed (${c.describe()}). The app package is compiled into the store '
        'build and is never patchable ($_storeRelease). Move code you want to patch into a feature package.',
      );
      continue;
    }
    final patchable = {PackageRole.feature.name, PackageRole.featureInternal.name};
    if (!patchable.contains(releaseRole) || !patchable.contains(role?.name)) {
      final reason = (graph.reasons[name] ?? const []).join('; ');
      refuse(
        '$name is a shared (host-owned) package${reason.isEmpty ? '' : ' ($reason)'} and changed '
        '(${c.describe()}). Its types and state belong to the store build, so a copy in a patch would be a '
        'different package ($_storeRelease).',
      );
      continue;
    }
    if (releaseRole != role!.name) {
      refuse('$name was a $releaseRole package in the release and is now ${role.name} ($_storeRelease).');
      continue;
    }
    var ok = true;
    if (c.nativeChanged) {
      refuse('$name: native code changed; only Dart code can be patched ($_storeRelease).');
      ok = false;
    }
    if (c.otherFilesChanged) {
      refuse('$name: files outside lib/ changed (assets, fonts, ...); patches carry no assets yet ($_storeRelease).');
      ok = false;
    }
    if (c.flutterSectionChanged) {
      refuse('$name: the `flutter:` section of pubspec.yaml changed (assets, fonts or plugin) ($_storeRelease).');
      ok = false;
    }
    final missing = c.addedDependencies.where((d) => !hostPackages.contains(d)).toList();
    if (missing.isNotEmpty) {
      refuse('$name: new dependencies ${missing.join(', ')} are not part of the store build ($_storeRelease).');
      ok = false;
    }
    if (c.addedDependencies.isNotEmpty && missing.isEmpty) {
      plan.notes.add('$name now also depends on ${c.addedDependencies.join(', ')} (already in the store build).');
    }
    if (c.changedDependencies.isNotEmpty) {
      plan.notes.add(
        '$name: dependency constraints changed (${c.changedDependencies.join(', ')}); the patch '
        'still uses the versions of the store build (pubspec.lock is unchanged).',
      );
    }
    if (ok && (c.sourceChanged || c.pubspecChanged)) {
      plan.changed.add(name);
      plan.why[name] = 'changed: ${c.describe()}';
    }
  }

  // Closure over feature and feature-internal dependents.
  final queue = [...plan.changed];
  plan.packages.addAll(plan.changed);
  while (queue.isNotEmpty) {
    final n = queue.removeLast();
    for (final d in graph.localDependentsOf(n)) {
      final r = graph.roles[d];
      if (r != PackageRole.feature && r != PackageRole.featureInternal) continue;
      if (plan.packages.add(d)) {
        plan.why[d] = 'depends on $n, which changed (closure rule)';
        queue.add(d);
      }
    }
  }

  // The store build must have a slot for every patched feature, with the same entry and contract.
  final releasePkgs = (diff.release['packages']! as Map).cast<String, Object?>();
  for (final f in plan.features) {
    final then = (releasePkgs[f] as Map?)?['entry'];
    final now = graph.features[f]?.toJson();
    if (then == null) {
      refuse('$f had no feature slot in the store build ($_storeRelease).');
    } else if (now == null ||
        canonicalJsonString((then as Map)['contract']) != canonicalJsonString(now['contract']) ||
        then['class'] != now['class']) {
      refuse('$f: its entry class or contract type changed since the release ($_storeRelease).');
    }
  }
  if (plan.packages.isNotEmpty && plan.features.isEmpty) {
    refuse('the changed packages (${(plan.packages.toList()..sort()).join(', ')}) are reached by no feature slot.');
  }
  return plan;
}
