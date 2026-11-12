// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi';
import 'dart:io';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'ffi', 'run': run};

typedef GetPidNative = Int32 Function();
typedef GetPidDart = int Function();

Future<Map<String, Object?>> run() async {
  final r = <String, Object?>{'dart:io pid': pid};
  try {
    r['DynamicLibrary.process()'] = DynamicLibrary.process().toString();
  } catch (e) {
    r['DynamicLibrary.process()'] = 'THREW ${e.runtimeType}: $e';
  }
  try {
    final getpid = DynamicLibrary.process().lookupFunction<GetPidNative, GetPidDart>('getpid');
    r['lookupFunction getpid()'] = getpid();
  } catch (e) {
    r['lookupFunction getpid()'] = 'THREW ${e.runtimeType}: $e';
  }
  try {
    r['Pointer.fromAddress'] = Pointer<Uint8>.fromAddress(0).address;
  } catch (e) {
    r['Pointer.fromAddress'] = 'THREW ${e.runtimeType}: $e';
  }
  return r;
}
