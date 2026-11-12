// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Entry point of the separate verifier process ":flutter_ota_verify" (FlutterOtaVerifierService).
//
// The service starts its own FlutterEngine on the app's AOT snapshot and runs
//   package:flutter_ota_system/src/bytecode/verifier_main.dart  flutterOtaVerifierMain
// This library is imported by the SDK's public library, so it is part of every app that uses the
// SDK, and @pragma('vm:entry-point') keeps the function (and its name) in the AOT snapshot. The
// app does not have to export anything.
//
// It loads ONE candidate module exactly as the app would: the patched Dart VM verifies every
// function's bytecode while reading it (Phase 3C), then the entry point runs, and every feature
// factory is called once. A malformed module that aborts the VM kills only this process; the app
// sees CRASHED and never activates the patch. The process is the same Linux user as the app
// (Android isolated processes cannot start Flutter in release builds, Phase 3C); it is a
// separate process, not a sandbox.

import 'dart:ui' show CallbackHandle, PluginUtilities;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'module_entry.dart';

const _channel = MethodChannel('flutter_ota/verifier');

/// Verifier process entry point. Not for app code.
@pragma('vm:entry-point')
Future<void> flutterOtaVerifierMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sw = Stopwatch()..start();
  Map<String, Object?> result;
  String? nonce;
  try {
    // One-shot: the native side answers "job" once, so module code cannot read the nonce later
    // and post a fake result.
    final job = (await _channel.invokeMapMethod<String, Object?>('job'))!;
    nonce = job['nonce'] as String?;
    final bytes = job['bytes']! as Uint8List;
    final handle = job['loaderHandle'] as int?;
    final loader = handle == null ? null : PluginUtilities.getCallbackFromHandle(CallbackHandle.fromRawHandle(handle));
    if (loader is! FlutterOtaModuleLoader) {
      result = {'status': 'UNAVAILABLE', 'detail': 'module loader not found in the verifier process'};
    } else {
      result = await verifyModuleBytes(bytes, loader);
    }
  } catch (e) {
    result = {'status': 'REJECTED', 'detail': '${e.runtimeType}: $e'};
  }
  result['verifier_ms'] = sw.elapsedMicroseconds / 1000;
  result['nonce'] = nonce;
  await _channel.invokeMethod<void>('result', result);
}

/// Loads [bytes] with [loader], checks the contract-3 entry result and calls every feature
/// factory once. Returns `{status: OK|REJECTED, detail}`. Shared with tests.
Future<Map<String, Object?>> verifyModuleBytes(Uint8List bytes, FlutterOtaModuleLoader loader) async {
  try {
    final r = await loader(Uint8List.fromList(bytes));
    final entry = parseModuleEntry(r);
    final smoke = <String>[];
    for (final MapEntry(:key, :value) in entry.features.entries) {
      final Object? instance;
      try {
        instance = value();
      } catch (e) {
        return {'status': 'REJECTED', 'detail': 'feature "$key" factory threw ${e.runtimeType}: $e'};
      }
      if (instance == null) return {'status': 'REJECTED', 'detail': 'feature "$key" factory returned null'};
      smoke.add('$key=${instance.runtimeType}');
    }
    return {'status': 'OK', 'detail': smoke.isEmpty ? 'no features' : smoke.join('; ')};
  } catch (e) {
    // A clean Dart error: bytecode verification failed, "library is already loaded", entry threw.
    return {'status': 'REJECTED', 'detail': '${e.runtimeType}: $e'};
  }
}
