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
import 'patch_id.dart';
import 'native_boot.dart';
import 'runtime.dart';

/// Runs **Android code patches** (`aot-bidiff-android-v1`): replaces the app's compiled Dart
/// code. **Experimental.**
///
/// A patch is a binary diff from the store build's `libapp.so` (all of the app's compiled Dart
/// code) to a new one. After the download is verified, the runtime rebuilds the new `libapp.so`
/// and checks both the base and the result hash against the signed values. The plugin's Android
/// code loads it on the next cold start, before any Dart code runs.
///
/// Requirements: Android, a **release** build (debug builds run Dart in JIT mode; there it
/// accepts no patches), and the exact store build registered with `ota release android`.
/// On other platforms and in debug builds it reports no supported formats, so the server offers
/// it nothing.
///
/// This runtime downloads and loads native executable code. Do not use it in apps distributed
/// through Google Play unless you have independently reviewed and confirmed compliance with
/// the applicable Google Play policies.
///
/// ```dart
/// final client = OtaClient(OtaConfig(
///   serverUrl: 'https://ota.example.com',
///   appSlug: 'my-app',
///   applicationId: '<server application id>',
///   releaseVersion: '1.0.0+1',
///   publicKeys: const {'prod-1': '<base64 point>'},
///   runtime: AotPatchRuntime(),
/// ));
/// ```
final class AotPatchRuntime implements PatchRuntime {
  /// Creates the Android code-patch runtime.
  AotPatchRuntime() : _native = _AotNativeRuntime(const MethodChannel('ota_client/aot'));

  final _AotNativeRuntime _native;

  /// The patch format this runtime runs: `aot-bidiff-android-v1`.
  static const format = 'aot-bidiff-android-v1';

  /// `{format}` on Android release builds once the native side is ready, otherwise empty.
  @override
  Set<String> get supportedFormats => _native.supportedFormats;

  /// `ota-aot-android-1`; must equal the release's runtime ABI on the server.
  @override
  String get runtimeAbi => _native.runtimeAbi;

  /// Rebuilds `libapp.so` from the verified diff into [patchDir] and checks the base and result
  /// hashes. Throws a [StateError] if code patches are unavailable or a hash does not match.
  @override
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir) =>
      _native.stage(patch, verifiedPayload, patchDir);

  /// Does nothing: the native side already chose and loaded the code before Dart started.
  @override
  Future<void> load(PatchRecord? patch, Directory? patchDir) => _native.load(patch, patchDir);
}

/// The native-boot view of a runtime, for [OtaClient]: [AotPatchRuntime]'s internal part, or a
/// test double that implements [NativeBootRuntime] directly. Null for other runtimes.
NativeBootRuntime? nativeBootRuntimeOf(PatchRuntime runtime) =>
    runtime is AotPatchRuntime ? runtime._native : (runtime is NativeBootRuntime ? runtime : null);

/// The implementation behind [AotPatchRuntime]; talks to OtaBoot.java over [MethodChannel].
class _AotNativeRuntime implements NativeBootRuntime {
  _AotNativeRuntime(this._channel);

  final MethodChannel _channel;
  Map<String, dynamic>? _report;

  static const format = AotPatchRuntime.format;

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
      debugPrint('flutter_ota_system: native boot report unavailable: $e');
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
      // The native side checks ids too (OtaPaths.java); never hand it one that names a path.
      if (p == null || dir == null || !isValidPatchId(p.id)) return null;
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
