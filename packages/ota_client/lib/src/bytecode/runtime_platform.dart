// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Dart side of the Android channel "flutter_ota/runtime" (OtaRuntimeChannel.java).

import 'dart:io';
import 'dart:ui' show PluginUtilities;

import 'package:flutter/services.dart';

import 'exit_info.dart';
import 'module_entry.dart';

/// Values the app process needs once per start.
class NativeStartupInfo {
  const NativeStartupInfo({required this.filesDir, required this.appVersion});

  /// Android `Context.getFilesDir()`.
  final String filesDir;

  /// `versionName+versionCode`, e.g. `1.0.0+1` (the server's release version).
  final String appVersion;
}

/// Outcome of loading a candidate module in the separate verifier process.
///
/// - `OK`: loaded, entry contract and feature factories checked;
/// - `REJECTED`: a clean error (e.g. the in-VM bytecode verifier refused it, a factory threw);
/// - `CRASHED`: the verifier process died after it took the module;
/// - `TIMEOUT`: no result in time; the verifier process was killed;
/// - `UNAVAILABLE`: the verifier could not start or could not get the module loader. Never OK.
class VerifyOutcome {
  const VerifyOutcome(this.status, this.detail, {this.ms});

  static VerifyOutcome fromMap(Map<Object?, Object?>? m) {
    if (m == null) return const VerifyOutcome('CRASHED', 'no result');
    final status = m['status'];
    const known = {'OK', 'REJECTED', 'CRASHED', 'TIMEOUT', 'UNAVAILABLE'};
    return VerifyOutcome(
      status is String && known.contains(status) ? status : 'CRASHED',
      '${m['detail'] ?? ''}',
      ms: (m['ms'] as num?)?.toDouble(),
    );
  }

  final String status;
  final String detail;
  final double? ms;

  bool get ok => status == 'OK';

  @override
  String toString() => '$status${ms == null ? '' : ' (${ms!.toStringAsFixed(0)} ms)'}: $detail';
}

/// Native services of the bytecode runtime. Replaced by a fake in tests.
abstract class FlutterOtaPlatform {
  Future<NativeStartupInfo> startupInfo();

  /// How the previous main process ended (API 30+), or null.
  Future<ExitInfo?> lastExit();

  /// SHA-256 of the installed store `libapp.so`, computed natively (never taken from input).
  Future<String> libappSha256();

  /// Loads [moduleFile] in the separate `:flutter_ota_verify` process.
  Future<VerifyOutcome> verifyInProcess(File moduleFile, FlutterOtaModuleLoader loader, {required Duration timeout});
}

/// The real implementation over the method channel.
class MethodChannelFlutterOtaPlatform implements FlutterOtaPlatform {
  static const channel = MethodChannel('flutter_ota/runtime');

  @override
  Future<NativeStartupInfo> startupInfo() async {
    final m = await channel.invokeMapMethod<String, Object?>('startupInfo');
    return NativeStartupInfo(filesDir: m!['filesDir']! as String, appVersion: m['appVersion']! as String);
  }

  @override
  Future<ExitInfo?> lastExit() async => ExitInfo.fromMap(await channel.invokeMapMethod<Object?, Object?>('lastExit'));

  @override
  Future<String> libappSha256() async {
    final v = await channel.invokeMethod<String>('libappSha256');
    if (v == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) throw StateError('libapp.so hash unavailable');
    return v;
  }

  @override
  Future<VerifyOutcome> verifyInProcess(
    File moduleFile,
    FlutterOtaModuleLoader loader, {
    required Duration timeout,
  }) async {
    // The verifier process runs flutterOtaVerifierMain (in this SDK) on a new engine, where no app
    // code has run. It finds the loader through its callback handle (library + name), which only
    // works for a top-level or static function marked @pragma('vm:entry-point').
    final handle = PluginUtilities.getCallbackHandle(loader);
    if (handle == null) {
      return const VerifyOutcome(
        'UNAVAILABLE',
        'the module loader is not a top-level or static function; the verifier process cannot find it',
      );
    }
    final m = await channel.invokeMapMethod<Object?, Object?>('verifyInProcess', {
      'path': moduleFile.path,
      'timeoutMs': timeout.inMilliseconds,
      'loaderHandle': handle.toRawHandle(),
    });
    return VerifyOutcome.fromMap(m);
  }
}
