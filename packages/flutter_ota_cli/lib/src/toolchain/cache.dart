// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;

/// Layout of the CLI cache (default `~/.cache/flutter_ota`, override `FLUTTER_OTA_CACHE`):
///
///     toolchains/<id>/      installed toolchains (flutter/, mirror/, tools/, install.json, ...)
///     toolchains/.tmp-*     installs in progress (renamed atomically when complete)
///     downloads/<sha256>    verified archives; `<sha256>.part` while downloading
///     metadata/             last verified index, projects that pin each toolchain
///     locks/<id>.lock       install locks
class CachePaths {
  CachePaths(this.root);

  factory CachePaths.fromEnvironment(Map<String, String> env) {
    final override = env['FLUTTER_OTA_CACHE'];
    if (override != null && override.isNotEmpty) return CachePaths(p.absolute(override));
    final xdg = env['XDG_CACHE_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : p.join(env['HOME'] ?? '.', '.cache');
    return CachePaths(p.join(base, 'flutter_ota'));
  }

  final String root;

  String get toolchains => p.join(root, 'toolchains');
  String get downloads => p.join(root, 'downloads');
  String get metadata => p.join(root, 'metadata');
  String get locks => p.join(root, 'locks');

  String toolchainDir(String id) => p.join(toolchains, id);
  String lockFile(String id) => p.join(locks, '$id.lock');
  String get cachedIndex => p.join(metadata, 'index.json');
  String get cachedIndexSource => p.join(metadata, 'index.source');
  String get projectsFile => p.join(metadata, 'projects.json');

  void ensure() {
    for (final d in [toolchains, downloads, metadata, locks]) {
      Directory(d).createSync(recursive: true);
    }
  }
}
