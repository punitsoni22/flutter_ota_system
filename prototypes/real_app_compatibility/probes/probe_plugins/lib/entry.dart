// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/services.dart';
// pkg_rename:keep
import 'package:shared_preferences/shared_preferences.dart' as host_prefs;
import 'package:shared_preferences/shared_preferences.dart' as copy_prefs;

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'plugins', 'run': run};

Future<Map<String, Object?>> run() async {
  final r = <String, Object?>{};
  Future<void> check(String name, FutureOr<Object?> Function() f) async {
    try {
      r[name] = await f();
    } catch (e) {
      r[name] = 'THREW ${e.runtimeType}: $e';
    }
  }

  final stamp = DateTime.now().millisecondsSinceEpoch.toString();
  await check('host wrapper (KeyValueStore) write+read', () async {
    final kv = ServiceLocator.instance.get<KeyValueStore>();
    await kv.setString('probe_key', 'host-wrapper-$stamp');
    return await kv.getString('probe_key');
  });
  await check('host plugin Dart API (AOT) called from bytecode', () async {
    final p = await host_prefs.SharedPreferences.getInstance();
    return p.getString('probe_key');
  });
  await check('COPY of plugin Dart wrapper (2.5.6) reads host-written value', () async {
    final p = await copy_prefs.SharedPreferences.getInstance();
    await p.reload();
    return p.getString('probe_key');
  });
  await check('COPY writes, host wrapper reads (same native store)', () async {
    final p = await copy_prefs.SharedPreferences.getInstance();
    await p.setString('copy_key', 'copy-$stamp');
    final h = await host_prefs.SharedPreferences.getInstance();
    await h.reload();
    return h.getString('copy_key');
  });
  await check('COPY: SharedPreferencesAsync API', () async {
    final a = copy_prefs.SharedPreferencesAsync();
    await a.setString('async_key', 'async-$stamp');
    return await a.getString('async_key');
  });
  await check('raw MethodChannel to host native code', () async {
    final m = await const MethodChannel('compat/exit_info').invokeMapMethod<String, Object?>('lastExit');
    return m == null ? 'null (no previous exit record)' : 'reason=${m['reason']}';
  });
  await check('MethodChannel to a channel with no native handler', () async {
    await const MethodChannel('compat/does_not_exist').invokeMethod<void>('x');
    return 'no error';
  });
  return r;
}
