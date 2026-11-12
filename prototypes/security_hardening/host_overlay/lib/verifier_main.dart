// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Entry point of the ISOLATED verifier. Phase 3C: runs in the Android isolated process
// ":otaverify_iso" (IsolatedVerifierService: separate UID, module received as bytes read from a
// read-only file descriptor) or, as a logged fallback, in the ":otaverify" process (VerifierService,
// module path). Its own FlutterEngine runs on the same AOT snapshot as the app.
//
// Phase 3C: the patched Dart VM verifies every function's bytecode while the module is read
// (runtime/vm/bytecode_verifier.cc); a malformed module now fails with a clean StateError
// ("Bytecode verification failed ...") before any of its code runs. Process isolation remains as
// a second layer for VM defects the verifier does not cover.
//
// It loads the candidate module exactly as the app would (the Dart VM reads every declaration and
// every function's bytecode at load time, then runs the entry point), checks the entry point's
// result against the host contracts, and runs a small smoke test of the slot objects. A malformed
// module that makes the VM abort kills only this process; the app sees CRASHED.

import 'dart:io';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:app_models/app_models.dart';
import 'package:dynamic_modules/dynamic_modules.dart' as dm;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('ota/verifier');

@pragma('vm:entry-point')
Future<void> verifierMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sw = Stopwatch()..start();
  Map<String, Object?> result;
  try {
    final job = await _channel.invokeMethod<Object?>('job');
    final bytes = job is Uint8List ? job : File(job! as String).readAsBytesSync();
    final Object? r = await dm.loadModuleFromBytes(Uint8List.fromList(bytes));
    final loadMs = sw.elapsedMicroseconds / 1000;
    if (r is! Map || r['contract'] != 2) {
      result = {'status': 'REJECTED', 'detail': 'entry point returned ${r.runtimeType}, not a contract-2 map'};
    } else {
      final problems = <String>[];
      final smoke = <String>[];
      const sample = Product(id: 'p1', title: 'Flutter Handbook', pricePaise: 49900, category: Category.books);
      for (final MapEntry(:key, :value) in r.entries) {
        switch (key) {
          case 'contract' || 'patch':
            break;
          case 'catalog':
            if (value is! CatalogFeature) {
              problems.add('catalog is ${value.runtimeType}, not the host CatalogFeature');
            } else {
              smoke.add('catalog.version=${value.version}');
              smoke.add('catalog.priceLabel=${value.priceLabel(sample)}');
            }
          case 'profile':
            if (value is! ProfileFeature) {
              problems.add('profile is ${value.runtimeType}, not the host ProfileFeature');
            } else {
              smoke.add('profile.version=${value.version}');
              smoke.add('profile.validateName=${value.validateName('ab')}');
            }
          case 'assets':
            if (value is! Map<String, Uint8List>) problems.add('assets has the wrong type');
          default:
            problems.add('unknown slot "$key"');
        }
      }
      result = problems.isEmpty
          ? {'status': 'OK', 'detail': smoke.join('; '), 'load_ms': loadMs}
          : {'status': 'REJECTED', 'detail': problems.join('; ')};
    }
  } catch (e) {
    // A clean Dart error (e.g. "library is already loaded", entry point threw).
    result = {'status': 'REJECTED', 'detail': '${e.runtimeType}: $e'};
  }
  result['ms'] = sw.elapsedMicroseconds / 1000;
  result['probes'] = _dartProbes();
  await _channel.invokeMethod<void>('result', result);
}

/// Isolation evidence from the Dart side of the verifier process.
String _dartProbes() {
  String attempt(String Function() f) {
    try {
      return f();
    } catch (e) {
      return 'DENIED(${e.runtimeType})';
    }
  }

  const store = '/data/user/0/io.github.punitsoni22.compat_host/files/ota';
  return [
    'dart_read_state=${attempt(() => 'ALLOWED(${File('$store/state.json').readAsBytesSync().length} bytes)')}',
    'dart_write_store=${attempt(() {
      final f = File('$store/iso_probe_dart.tmp')..writeAsStringSync('x');
      f.deleteSync();
      return 'ALLOWED';
    })}',
  ].join(',');
}
