// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Picks the toolchain for a project that has no `flutter_ota.lock` yet: the newest toolchain of
/// the index that the project can actually build with.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../doctor/android_build_versions.dart';
import 'index.dart';

/// The chosen entry and why the newer ones were skipped (for the user).
class ToolchainChoice {
  ToolchainChoice(this.entry, this.skipped);

  final ToolchainEntry? entry;

  /// `<toolchain id>: <reason>` for every newer entry that does not fit the project.
  final List<String> skipped;
}

/// Chooses from [compatible] (oldest first, as in the index) the newest entry whose Dart version
/// satisfies the project's `environment: sdk:` constraint and whose enforced Android build tool
/// minimums the project's `android/` files meet. Without a project, the newest entry is chosen.
ToolchainChoice chooseToolchain(List<ToolchainEntry> compatible, {String? projectDir}) {
  if (projectDir == null) return ToolchainChoice(compatible.isEmpty ? null : compatible.last, const []);
  final sdk = _sdkConstraint(projectDir);
  final android = AndroidBuildVersions.read(projectDir);
  final skipped = <String>[];
  for (final e in compatible.reversed) {
    if (sdk != null && !dartSatisfies(sdk, e.dart)) {
      skipped.add('${e.id}: Dart ${e.dart} does not match pubspec.yaml "sdk: $sdk"');
      continue;
    }
    final min = minimumsFor(e.flutter);
    final problems = min == null ? const <String>[] : android.problemsAgainst(min);
    if (problems.isNotEmpty) {
      skipped.add('${e.id}: needs newer Android build tools (${problems.join(', ')})');
      continue;
    }
    return ToolchainChoice(e, skipped);
  }
  return ToolchainChoice(null, skipped);
}

String? _sdkConstraint(String projectDir) {
  final f = File(p.join(projectDir, 'pubspec.yaml'));
  if (!f.existsSync()) return null;
  try {
    final y = loadYaml(f.readAsStringSync());
    final env = y is YamlMap ? y['environment'] : null;
    final sdk = env is YamlMap ? env['sdk'] : null;
    return sdk is String ? sdk.trim() : null;
  } on YamlException {
    return null;
  }
}

/// Whether [version] satisfies a pub SDK constraint: `^x.y.z`, `any`, an exact version, or ranges
/// built from `>=`, `>`, `<=`, `<` (for example `">=3.8.0 <4.0.0"`). Unknown syntax counts as
/// satisfied (the pub resolver reports it during the build).
bool dartSatisfies(String constraint, String version) {
  final c = constraint.replaceAll('"', '').replaceAll("'", '').trim();
  if (c.isEmpty || c == 'any') return true;
  if (c.startsWith('^')) {
    final min = c.substring(1).trim();
    final parts = min.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    // Caret: below the next breaking version (major for >= 1.0.0, minor for 0.x).
    final upper = parts.isNotEmpty && parts[0] > 0
        ? '${parts[0] + 1}.0.0'
        : '0.${(parts.length > 1 ? parts[1] : 0) + 1}.0';
    return compareVersions(version, min) >= 0 && compareVersions(version, upper) < 0;
  }
  final ops = RegExp(r'(>=|<=|>|<)\s*([0-9][0-9A-Za-z.\-+]*)').allMatches(c).toList();
  if (ops.isEmpty) {
    return RegExp(r'^[0-9]').hasMatch(c) ? compareVersions(version, c) == 0 : true;
  }
  for (final m in ops) {
    final d = compareVersions(version, m.group(2)!);
    final ok = switch (m.group(1)) {
      '>=' => d >= 0,
      '>' => d > 0,
      '<=' => d <= 0,
      _ => d < 0,
    };
    if (!ok) return false;
  }
  return true;
}
