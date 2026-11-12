// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:compat_suites/compat_suites.dart';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'multi_b', 'run': run};

Future<Map<String, Object?>> run() async {
  final r = <String, Object?>{};
  Future<void> check(String name, FutureOr<Object?> Function() f) async {
    try {
      r[name] = await f();
    } catch (e) {
      r[name] = 'THREW ${e.runtimeType}: $e';
    }
  }

  await check('registry names visible to B', () => PatchRegistry.names.toList());
  await check('call A through a HOST interface (Greeter)', () => (PatchRegistry.lookup('a.greeter')! as Greeter).greet('B'));
  await check('call A closure through a function type', () => (PatchRegistry.lookup('a.fn')! as String Function(String))('hi'));
  await check('runtimeType of A-only class', () => PatchRegistry.lookup('a.counter').runtimeType.toString());
  return r;
}
