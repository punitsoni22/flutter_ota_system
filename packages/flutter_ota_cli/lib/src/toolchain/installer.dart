// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import 'cache.dart';
import 'disk_space.dart';
import 'downloader.dart';
import 'index.dart';
import 'install_lock.dart';
import 'records.dart';

/// Installs a toolchain into `toolchains/<id>`:
///
/// 1. take `locks/<id>.lock` (one install per toolchain at a time);
/// 2. check free disk space for the downloads plus extraction;
/// 3. download both archives (resumable, size + SHA-256 checked against the signed index);
/// 4. extract the stock SDK and the overlay into `toolchains/.tmp-<id>-<pid>`;
/// 5. verify every overlay file, the content-hash `toolchain.json` and the stock files the overlay
///    replaces, then apply the overlay (our gen_snapshot, Maven mirror, tool snapshots, notices);
/// 6. write `install.json` (file hashes) and rename the temp directory atomically into place.
///
/// An interrupted install leaves only a temp directory, which the next install removes.
class ToolchainInstaller {
  ToolchainInstaller({required this.cache, required this.downloader, required this.diskSpace, this.log});

  final CachePaths cache;
  final Downloader downloader;
  final DiskSpaceProbe diskSpace;
  final void Function(String)? log;

  bool isInstalled(ToolchainEntry e) {
    final rec = readInstallRecord(cache.toolchainDir(e.id));
    return rec != null && rec['toolchain_id'] == e.toolchainId;
  }

  Future<String> install(ToolchainEntry e, {bool force = false}) async {
    if (e.host != supportedHost) {
      throw CliException('Toolchain ${e.id} is for ${e.host}; this CLI supports $supportedHost hosts only.');
    }
    cache.ensure();
    final lock = InstallLock.acquire(cache.lockFile(e.id), what: 'toolchain ${e.id}');
    try {
      _removeStaleTemps();
      final finalDir = cache.toolchainDir(e.id);
      if (!force && isInstalled(e)) {
        log?.call('Toolchain ${e.id} is already installed.');
        return finalDir;
      }
      final needed =
          downloader.remainingBytes(e.sdk) +
          downloader.remainingBytes(e.overlay) +
          e.sdk.extractEstimate +
          e.overlay.extractEstimate;
      await requireDiskSpace(diskSpace, cache.root, needed, 'installing toolchain ${e.id}');

      final sdkArchive = await downloader.fetch(e.sdk, label: 'Flutter ${e.flutter} SDK');
      final overlayArchive = await downloader.fetch(e.overlay, label: 'OTA overlay for ${e.id}');

      final tmp = Directory(p.join(cache.toolchains, '.tmp-${e.id}-$pid-${DateTime.now().microsecondsSinceEpoch}'));
      tmp.createSync(recursive: true);
      try {
        await _build(e, tmp.path, sdkArchive, overlayArchive);
        final dest = Directory(finalDir);
        if (dest.existsSync()) {
          // A previous install that is incomplete, corrupted or being replaced with --force.
          final trash = p.join(cache.toolchains, '.tmp-trash-${e.id}-$pid-${DateTime.now().microsecondsSinceEpoch}');
          dest.renameSync(trash);
          Directory(trash).deleteSync(recursive: true);
        }
        tmp.renameSync(finalDir);
      } catch (_) {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        rethrow;
      }
      log?.call('Installed toolchain ${e.id} in $finalDir');
      return finalDir;
    } finally {
      lock.release();
    }
  }

  Future<void> _build(ToolchainEntry e, String tmp, String sdkArchive, String overlayArchive) async {
    // Stock SDK.
    final sdkStage = p.join(tmp, '.sdk-extract');
    log?.call('Extracting Flutter ${e.flutter} SDK...');
    await _extract(sdkArchive, sdkStage, e.sdk, () {
      // A corrupted archive that still matched its hash can only mean a bad index; but a cached
      // archive is re-hashed before use, so delete it to force a clean download next time.
      File(sdkArchive).deleteSync();
    });
    final sdkRoot = p.join(sdkStage, e.sdk.root ?? 'flutter');
    if (!File(p.join(sdkRoot, 'bin', 'flutter')).existsSync()) {
      throw IntegrityException('The Flutter SDK archive has no ${e.sdk.root ?? 'flutter'}/bin/flutter.');
    }
    final flutterDir = p.join(tmp, 'flutter');
    Directory(sdkRoot).renameSync(flutterDir);
    Directory(sdkStage).deleteSync(recursive: true);

    final engineFile = File(p.join(flutterDir, 'bin', 'internal', 'engine.version'));
    if (!engineFile.existsSync() || engineFile.readAsStringSync().trim() != e.engine) {
      throw IntegrityException('The Flutter SDK archive is not built from engine ${e.engine}.');
    }

    // Overlay.
    final ov = p.join(tmp, '.overlay');
    log?.call('Applying the OTA overlay...');
    await _extract(overlayArchive, ov, e.overlay, () => File(overlayArchive).deleteSync());
    final OverlayManifest manifest;
    try {
      manifest = OverlayManifest.read(p.join(ov, overlayManifestName));
    } on Object {
      throw IntegrityException('The overlay archive has no valid $overlayManifestName.');
    }
    if (manifest.toolchain != e.id || manifest.toolchainId != e.toolchainId || manifest.engine != e.engine) {
      throw IntegrityException('The overlay is for ${manifest.toolchain} (${manifest.toolchainId}), not ${e.id}.');
    }
    final files = manifest.files;
    for (final entry in files.entries) {
      if (!isSafeRelative(entry.key)) throw IntegrityException('Unsafe path in overlay: ${entry.key}');
      final f = File(p.join(ov, entry.key));
      if (!f.existsSync() || await sha256OfFile(f.path) != entry.value) {
        throw IntegrityException('Overlay file ${entry.key} is missing or does not match its hash.');
      }
    }
    for (final required in [
      'toolchain.json',
      'sdk/$genSnapshotSdkPath',
      for (final t in toolSnapshots) 'tools/$t.aot',
      ...mirrorFilesFor(e.engine),
    ]) {
      if (!files.containsKey(required)) throw IntegrityException('The overlay does not contain $required.');
    }
    final tj = jsonDecode(File(p.join(ov, 'toolchain.json')).readAsStringSync()) as Map<String, Object?>;
    if (tj['id'] != e.toolchainId || computeToolchainId(tj) != e.toolchainId) {
      throw IntegrityException('toolchain.json does not hash to the toolchain_id ${e.toolchainId} in the index.');
    }

    // The overlay may only replace stock files it knows (built for exactly this SDK).
    for (final r in manifest.sdkReplacements.entries) {
      if (!isSafeRelative(r.key) || !files.containsKey('sdk/${r.key}')) {
        throw IntegrityException('Invalid SDK replacement ${r.key}.');
      }
      final target = File(p.join(flutterDir, r.key));
      if (!target.existsSync()) {
        throw IntegrityException('The stock SDK has no ${r.key}; the overlay cannot be applied.');
      }
      if (await sha256OfFile(target.path) != r.value) {
        throw IntegrityException('The stock SDK file ${r.key} is not the one the overlay was built for.');
      }
    }
    for (final rel in files.keys) {
      final src = p.join(ov, rel);
      final dst = p.join(tmp, installedPathOf(rel));
      Directory(p.dirname(dst)).createSync(recursive: true);
      final d = File(dst);
      if (d.existsSync()) d.deleteSync();
      File(src).renameSync(dst);
    }
    File(p.join(ov, overlayManifestName)).renameSync(p.join(tmp, overlayManifestName));
    Directory(ov).deleteSync(recursive: true);
    await _chmodExecutable(p.join(flutterDir, genSnapshotSdkPath));

    // Install record (written last; its presence marks a complete install).
    final recorded = <String, String>{};
    for (final rel in files.keys) {
      final inst = installedPathOf(rel);
      recorded[inst] = files[rel]!;
    }
    for (final rel in recordedSdkFiles) {
      final f = File(p.join(flutterDir, rel));
      if (f.existsSync()) recorded['flutter/$rel'] = await sha256OfFile(f.path);
    }
    recorded[overlayManifestName] = await sha256OfFile(p.join(tmp, overlayManifestName));
    final record = {
      'format': 1,
      'toolchain': e.id,
      'toolchain_id': e.toolchainId,
      'flutter': e.flutter,
      'dart': e.dart,
      'engine': e.engine,
      'dart_revision': e.dartRevision,
      'host': e.host,
      'target': e.target,
      'installed_at': DateTime.now().toUtc().toIso8601String(),
      'artifacts': {'flutter_sdk': e.sdk.sha256, 'overlay': e.overlay.sha256},
      'files': recorded,
    };
    File(
      p.join(tmp, installRecordName),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(record), flush: true);
  }

  Future<void> _extract(String archive, String dest, ToolchainArtifact a, void Function() onCorrupt) async {
    Directory(dest).createSync(recursive: true);
    // GNU tar: detects gzip/xz itself, refuses member names with `..`, strips leading `/`.
    final r = await Process.run('tar', ['-x', '-f', archive, '-C', dest, '--no-same-owner']);
    if (r.exitCode != 0) {
      onCorrupt();
      throw IntegrityException(
        'Could not extract ${p.basename(archive)} (${a.url}): ${(r.stderr as String).trim()}\n'
        'The cached archive was deleted; run the command again to download it fresh.',
      );
    }
  }

  Future<void> _chmodExecutable(String path) async {
    await Process.run('chmod', ['0755', path]);
  }

  /// Removes temp directories left by installs whose process is gone.
  void _removeStaleTemps() {
    final dir = Directory(cache.toolchains);
    if (!dir.existsSync()) return;
    for (final d in dir.listSync().whereType<Directory>()) {
      final name = p.basename(d.path);
      final m = RegExp(r'^\.tmp-(?:trash-)?.+-(\d+)-\d+$').firstMatch(name);
      if (m == null) continue;
      final owner = int.parse(m.group(1)!);
      if (!processAlive(owner)) {
        log?.call('Removing leftovers of an interrupted install: $name');
        d.deleteSync(recursive: true);
      }
    }
  }
}

/// Reads `install.json`, or null if the toolchain is not (completely) installed.
Map<String, Object?>? readInstallRecord(String toolchainDir) {
  final f = File(p.join(toolchainDir, installRecordName));
  if (!f.existsSync()) return null;
  try {
    final j = jsonDecode(f.readAsStringSync());
    return j is Map<String, Object?> && j['format'] == 1 ? j : null;
  } on FormatException {
    return null;
  }
}
