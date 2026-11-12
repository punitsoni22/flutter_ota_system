// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../config/user_config.dart';
import '../context.dart';
import '../errors.dart';
import '../project/lockfile.dart';
import 'cache.dart';
import 'disk_space.dart';
import 'downloader.dart';
import 'index.dart';
import 'installer.dart';
import 'records.dart';
import 'transport.dart';
import 'trusted_keys.dart';

/// Paths and build environment of an installed, verified toolchain. This is what later
/// milestones (release, patch) use; they must never run the developer's global Flutter.
class ResolvedToolchain {
  ResolvedToolchain(this.id, this.toolchainId, this.root);

  final String id;
  final String toolchainId;

  /// `toolchains/<id>`
  final String root;

  String get flutterSdk => p.join(root, 'flutter');
  String get flutterBin => p.join(flutterSdk, 'bin', 'flutter');
  String get dartBin => p.join(flutterSdk, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
  String get dartAotRuntime => p.join(flutterSdk, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime');
  String get genSnapshot => p.join(flutterSdk, genSnapshotSdkPath);

  /// Local Maven mirror (contains `download.flutter.io/...`).
  String get mirrorDir => p.join(root, 'mirror');

  /// Isolated Gradle home, so no cached stock engine can be picked up.
  String get gradleHome => p.join(root, 'gradle-home');
  String get toolchainJson => p.join(root, 'toolchain.json');
  Map<String, String> get toolSnapshotPaths => {for (final t in toolSnapshots) t: p.join(root, 'tools', '$t.aot')};

  /// Environment for `flutter build` with this toolchain.
  Map<String, String> get buildEnvironment => {
    'FLUTTER_STORAGE_BASE_URL': 'file://$mirrorDir',
    'GRADLE_USER_HOME': gradleHome,
    'FLUTTER_SUPPRESS_ANALYTICS': 'true',
  };
}

/// One doctor result line.
class DoctorCheck {
  DoctorCheck(this.name, this.ok, this.detail, {this.warning = false});
  final String name;
  final bool ok;
  final bool warning;
  final String detail;
}

class ToolchainManager {
  ToolchainManager(this.ctx) : cache = CachePaths.fromEnvironment(ctx.environment);

  final CliContext ctx;
  final CachePaths cache;

  UserConfig get config => UserConfig.load(ctx.environment);

  Map<String, String> get trustedKeys => {...embeddedToolchainKeys, ...config.toolchainKeys};

  Uri indexUrl() {
    final v = config.resolve('toolchain-index-url', ctx.environment, builtIn: defaultToolchainIndexUrl);
    if (v.value == null) {
      throw CliException(
        'No toolchain index is configured (no official index is published yet).\n'
        'Point the CLI at a signed index, for example a local mirror:\n'
        '  flutter_ota config set toolchain-index-url file:///path/to/mirror/index.json',
      );
    }
    final raw = v.value!;
    final uri = raw.startsWith('/') ? Uri.file(raw) : Uri.parse(raw);
    checkUrlAllowed(uri);
    return uri;
  }

  /// Fetches and verifies the index. If the network fails, falls back to the last verified copy
  /// from the same source (verified again). Signature verification is never skipped.
  Future<ToolchainIndex> loadIndex() async {
    final url = indexUrl();
    final keys = trustedKeys;
    cache.ensure();
    final client = ctx.httpClientFactory();
    try {
      final bytes = await fetchBytes(url, client);
      final index = ToolchainIndex.verifyAndParse(bytes, keys, url);
      _checkSerial(index);
      File(cache.cachedIndex).writeAsBytesSync(bytes, flush: true);
      File(cache.cachedIndexSource).writeAsStringSync(url.toString());
      return index;
    } on IndexVerificationException {
      rethrow;
    } on CliException catch (e) {
      final cached = File(cache.cachedIndex);
      final src = File(cache.cachedIndexSource);
      if (cached.existsSync() && src.existsSync() && src.readAsStringSync() == url.toString()) {
        ctx.log('warning: ${e.message}\nUsing the last verified copy of the toolchain index.');
        return ToolchainIndex.verifyAndParse(cached.readAsBytesSync(), keys, url);
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  void _checkSerial(ToolchainIndex index) {
    final f = File(p.join(cache.metadata, 'index.serial'));
    final seen = f.existsSync() ? int.tryParse(f.readAsStringSync().trim()) ?? 0 : 0;
    if (index.serial < seen) {
      throw IndexVerificationException(
        'The toolchain index (serial ${index.serial}) is older than one already seen '
        '(serial $seen). Refusing it: an old index may list withdrawn toolchains.',
      );
    }
    if (index.serial > seen) f.writeAsStringSync('${index.serial}\n');
  }

  ToolchainInstaller installer(http.Client client) => ToolchainInstaller(
    cache: cache,
    downloader: Downloader(downloadsDir: cache.downloads, client: client, diskSpace: ctx.diskSpace, log: ctx.log),
    diskSpace: ctx.diskSpace,
    log: ctx.log,
  );

  Future<String> install(ToolchainEntry e, {bool force = false}) async {
    final client = ctx.httpClientFactory();
    try {
      return await installer(client).install(e, force: force);
    } finally {
      client.close();
    }
  }

  /// Installed toolchains: id -> install record.
  Map<String, Map<String, Object?>> installed() {
    final out = <String, Map<String, Object?>>{};
    final dir = Directory(cache.toolchains);
    if (!dir.existsSync()) return out;
    for (final d in dir.listSync().whereType<Directory>()) {
      final name = p.basename(d.path);
      if (name.startsWith('.')) continue;
      final rec = readInstallRecord(d.path);
      if (rec != null) out[name] = rec;
    }
    return out;
  }

  /// Resolves the toolchain pinned by [lock], verifying every recorded file. Throws
  /// [ToolchainUnavailableException] when it is missing or modified; there is no fallback.
  Future<ResolvedToolchain> resolve(Lockfile lock, {String? lockPath}) async {
    final dir = cache.toolchainDir(lock.toolchain);
    final rec = readInstallRecord(dir);
    if (rec == null) {
      throw ToolchainUnavailableException(
        'The toolchain ${lock.toolchain} pinned in $lockFileName is not installed.\n'
        'Install it with:  flutter_ota toolchain install\n'
        'flutter_ota never falls back to a stock or global Flutter SDK.',
      );
    }
    if (rec['toolchain_id'] != lock.toolchainId || rec['engine'] != lock.engine || rec['flutter'] != lock.flutter) {
      throw ToolchainUnavailableException(
        'The installed toolchain ${lock.toolchain} does not match $lockFileName '
        '(different toolchain_id). Reinstall it with:  flutter_ota toolchain install --force',
      );
    }
    final bad = await verifyRecordedFiles(dir, rec);
    if (bad.isNotEmpty) {
      throw ToolchainUnavailableException(
        'The installed toolchain ${lock.toolchain} failed verification '
        '(${bad.take(3).join(', ')}${bad.length > 3 ? ', ...' : ''}).\n'
        'Reinstall it with:  flutter_ota toolchain install --force\n'
        'flutter_ota never falls back to a stock or global Flutter SDK.',
      );
    }
    if (lockPath != null) recordProjectUse(lockPath, lock.toolchain);
    return ResolvedToolchain(lock.toolchain, lock.toolchainId, dir);
  }

  /// Returns the recorded files that are missing or changed.
  Future<List<String>> verifyRecordedFiles(String dir, Map<String, Object?> rec) async {
    final files = rec['files'];
    if (files is! Map) return ['install.json'];
    final bad = <String>[];
    for (final e in files.entries) {
      final rel = e.key as String;
      if (!isSafeRelative(rel)) {
        bad.add(rel);
        continue;
      }
      final f = File(p.join(dir, rel));
      if (!f.existsSync() || await sha256OfFile(f.path) != e.value) bad.add(rel);
    }
    return bad;
  }

  /// Remembers that the project with [lockPath] pins [toolchain] (used by `clean --unused`).
  void recordProjectUse(String lockPath, String toolchain) {
    cache.ensure();
    final f = File(cache.projectsFile);
    final map = _readProjects();
    map[p.absolute(lockPath)] = toolchain;
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(map));
  }

  Map<String, String> _readProjects() {
    final f = File(cache.projectsFile);
    if (!f.existsSync()) return {};
    try {
      return (jsonDecode(f.readAsStringSync()) as Map).cast<String, String>();
    } on Object {
      return {};
    }
  }

  /// Toolchain ids pinned by known projects whose lock file still exists and still pins them.
  Set<String> pinnedToolchains() {
    final pinned = <String>{};
    _readProjects().forEach((lockPath, id) {
      final f = File(lockPath);
      if (!f.existsSync()) return;
      try {
        final lock = Lockfile.parse(f.readAsStringSync(), lockPath);
        pinned.add(lock.toolchain);
      } on CliException {
        // Unreadable lock: ignore.
      }
    });
    return pinned;
  }

  /// Health checks of one installed toolchain. Never runs or changes the global Flutter.
  Future<List<DoctorCheck>> doctor(String id) async {
    final checks = <DoctorCheck>[];
    final dir = cache.toolchainDir(id);
    final rec = readInstallRecord(dir);
    if (rec == null) {
      checks.add(
        DoctorCheck('installed', false, 'not installed (or install incomplete): run flutter_ota toolchain install'),
      );
      return checks;
    }
    checks.add(DoctorCheck('installed', true, dir));
    final bad = await verifyRecordedFiles(dir, rec);
    final count = (rec['files'] as Map?)?.length ?? 0;
    checks.add(
      DoctorCheck(
        'file hashes',
        bad.isEmpty,
        bad.isEmpty ? '$count recorded files match install.json' : 'changed or missing: ${bad.join(', ')}',
      ),
    );
    final r = ResolvedToolchain(id, rec['toolchain_id'] as String, dir);
    final ovFile = File(p.join(dir, overlayManifestName));
    var overlayOk = false;
    if (ovFile.existsSync()) {
      final ov = OverlayManifest.read(ovFile.path);
      final expected = ov.files['sdk/$genSnapshotSdkPath'];
      overlayOk =
          expected != null &&
          File(r.genSnapshot).existsSync() &&
          await sha256OfFile(r.genSnapshot) == expected &&
          ov.sdkReplacements[genSnapshotSdkPath] != expected;
    }
    checks.add(
      DoctorCheck(
        'overlay applied',
        overlayOk,
        overlayOk ? 'gen_snapshot is the OTA build (not the stock one)' : 'gen_snapshot is not the OTA build',
      ),
    );
    final missingMirror = [
      for (final m in mirrorFilesFor(rec['engine'] as String))
        if (!File(p.join(dir, m)).existsSync()) m,
    ];
    checks.add(
      DoctorCheck(
        'maven mirror',
        missingMirror.isEmpty,
        missingMirror.isEmpty ? 'libflutter + embedding artifacts present' : 'missing: ${missingMirror.join(', ')}',
      ),
    );
    final missingTools = [
      for (final t in r.toolSnapshotPaths.entries)
        if (!File(t.value).existsSync()) t.key,
    ];
    checks.add(
      DoctorCheck(
        'tool snapshots',
        missingTools.isEmpty,
        missingTools.isEmpty ? toolSnapshots.join(', ') : 'missing: ${missingTools.join(', ')}',
      ),
    );
    var tjOk = false;
    try {
      final tj = jsonDecode(File(r.toolchainJson).readAsStringSync()) as Map<String, Object?>;
      tjOk = tj['id'] == rec['toolchain_id'] && computeToolchainId(tj) == rec['toolchain_id'];
    } on Object {
      tjOk = false;
    }
    checks.add(DoctorCheck('toolchain id', tjOk, rec['toolchain_id'] as String));
    final engineFile = File(p.join(r.flutterSdk, 'bin', 'internal', 'engine.version'));
    final engineOk = engineFile.existsSync() && engineFile.readAsStringSync().trim() == rec['engine'];
    checks.add(DoctorCheck('engine pin', engineOk, rec['engine'] as String));
    final flutterOk = File(r.flutterBin).existsSync();
    checks.add(DoctorCheck('flutter binary', flutterOk, r.flutterBin));
    final free = await ctx.diskSpace(cache.root);
    const want = 5 * 1024 * 1024 * 1024;
    checks.add(
      DoctorCheck(
        'disk space',
        true,
        free == null ? 'unknown' : '${formatBytes(free)} free${free < want ? ' (builds need several GB)' : ''}',
        warning: free != null && free < want,
      ),
    );
    checks.add(
      DoctorCheck(
        'isolation',
        true,
        'builds use this SDK, FLUTTER_STORAGE_BASE_URL=file://${r.mirrorDir} and GRADLE_USER_HOME=${r.gradleHome}; '
            'your global Flutter is never used or changed',
      ),
    );
    return checks;
  }
}
