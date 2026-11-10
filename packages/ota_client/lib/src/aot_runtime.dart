// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bsdiff.dart';
import 'models.dart';
import 'runtime.dart';

/// `aot-bidiff-android-v1`: real Dart code patches on Android.
///
/// A patch is a binary diff from the store's libapp.so (all the app's compiled Dart code) to the
/// new one. [stage] rebuilds the new libapp.so and checks both hashes; the native side of this
/// plugin loads it on the next start, before any Dart runs (see OtaBoot.java).
class AotPatchRuntime implements NativeBootRuntime {
  AotPatchRuntime({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('ota_client/aot');

  final MethodChannel _channel;
  Map<String, dynamic>? _report;

  static const format = 'aot-bidiff-android-v1';

  bool get _enabled => _report?['enabled'] == true;

  @override
  Set<String> get supportedFormats => _enabled ? const {format} : const {};

  @override
  String get runtimeAbi => 'ota-aot-android-1';

  @override
  Future<NativeBootReport> readBootReport() async {
    try {
      if (!Platform.isAndroid) return const NativeBootReport(enabled: false);
      _report = await _channel.invokeMapMethod<String, dynamic>('report');
    } catch (e) {
      debugPrint('ota_client: native boot report unavailable: $e');
      _report = null;
    }
    final r = _report;
    if (r == null) return const NativeBootReport(enabled: false);
    return NativeBootReport(
      enabled: _enabled,
      loadedPatchId: r['loaded_patch_id'] as String?,
      failedPatchIds: [...(r['failed_patch_ids'] as List? ?? const []).cast<String>()],
    );
  }

  @override
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir) async {
    if (!_enabled) throw StateError('code patches need a release build on Android');
    final base = await _channel.invokeMethod<String>('extractBase', {'abi': patch.arch});
    if (base == null) throw StateError('store libapp.so not found');
    await patchDir.create(recursive: true);
    final out = '${patchDir.path}/libapp.so';
    try {
      // Hashing and patching ~20 MB takes a moment: keep it off the UI thread.
      await Isolate.run(() => _rebuild(base, verifiedPayload.path, out, patch.baseArtifactSha256, patch.resultSha256));
    } finally {
      try {
        await File(base).delete();
      } catch (_) {}
    }
  }

  static void _rebuild(String basePath, String diffPath, String outPath, String baseSha, String resultSha) {
    final old = File(basePath).readAsBytesSync();
    if (sha256.convert(old).toString() != baseSha) {
      throw StateError('this patch was built for a different store build (base hash mismatch)');
    }
    final rebuilt = applyOtaDiff(old, File(diffPath).readAsBytesSync());
    if (sha256.convert(rebuilt).toString() != resultSha) {
      throw StateError('rebuilt code does not match the signed hash');
    }
    final tmp = File('$outPath.tmp')..writeAsBytesSync(rebuilt, flush: true);
    tmp.renameSync(outPath);
  }

  @override
  Future<void> load(PatchRecord? patch, Directory? patchDir) async {
    // Nothing to do: the native side already loaded the code before Dart started.
  }

  @override
  Future<void> setNextBoot({PatchRecord? next, Directory? nextDir, PatchRecord? good, Directory? goodDir}) async {
    final r = _report;
    if (r == null || !_enabled) return;
    Map<String, dynamic>? entry(PatchRecord? p, Directory? dir) {
      if (p == null || dir == null) return null;
      final file = File('${dir.path}/libapp.so');
      if (!file.existsSync()) return null;
      return {'id': p.id, 'number': p.number, 'file': file.path, 'sha256': p.resultSha256, 'size': file.lengthSync()};
    }

    final json = jsonEncode({
      'install_stamp': r['install_stamp'],
      'next': entry(next, nextDir) ?? entry(good, goodDir),
      'good': entry(good, goodDir),
    });
    final dir = Directory(r['boot_dir'] as String);
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/boot.json.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename('${dir.path}/boot.json');
  }
}
