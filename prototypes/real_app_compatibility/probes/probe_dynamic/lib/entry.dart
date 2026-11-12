// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:shared_state/shared_state.dart';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'dynamic', 'run': run};

class Own {
  int get value => 7;
  int twice(int x) => x * 2;
}

Future<Map<String, Object?>> run() async {
  final r = <String, Object?>{};
  Future<void> check(String name, FutureOr<Object?> Function() f) async {
    try {
      r[name] = await f();
    } catch (e) {
      r[name] = 'THREW ${e.runtimeType}: $e';
    }
  }

  await check('dynamic getter on module class', () => (Own() as dynamic).value);
  await check('dynamic method on module class', () => (Own() as dynamic).twice(21));
  await check('noSuchMethod on module class', () => (Own() as dynamic).missing());
  await check("jsonDecode(s)['id'] (dynamic [] on a dart:core Map)", () => jsonDecode('{"id": "p1"}')['id']);
  await check('dynamic getter on host User (app_models: dynamically-callable)', () => (AppState.instance.currentUser as dynamic).name);
  await check('dynamic method on host User (app_models: dynamically-callable)', () => jsonEncode((AppState.instance.currentUser as dynamic).toJson()));
  await check('dynamic getter on host AppConfig (app_core: NOT dynamically-callable)', () => (ServiceLocator.instance.get<AppConfig>() as dynamic).environment);
  await check('same, repeated 3x (reproducible?)', () => [
        for (var i = 0; i < 3; i++) '${(ServiceLocator.instance.get<AppConfig>() as dynamic).environment}',
      ]);
  await check('dynamic getter on host AppConfig.apiBase (NOT dynamically-callable)', () => '${(ServiceLocator.instance.get<AppConfig>() as dynamic).apiBase}');
  await check('typed access for comparison', () => ServiceLocator.instance.get<AppConfig>().environment);
  await check('dynamic call on module A object (other module)', () {
    final dynamic c = PatchRegistry.lookup('a.counter');
    return c == null ? 'module A not loaded' : c.increment();
  });
  return r;
}
