// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:app_core/app_core.dart';
import 'package:flutter/services.dart';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'assets', 'run': run};

// 2x3 PNG embedded in the module.
final Uint8List embeddedPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEElEQVR4nGPgOsEFRAwoFAA2OQUpvpoWdwAAAABJRU5ErkJggg==');

Future<Map<String, Object?>> run() async {
  final r = <String, Object?>{};
  Future<void> check(String name, FutureOr<Object?> Function() f) async {
    try {
      r[name] = await f();
    } catch (e) {
      r[name] = 'THREW ${e.runtimeType}: $e';
    }
  }

  await check('read existing APK asset (rootBundle.loadString)', () async => jsonDecode(await rootBundle.loadString('assets/config.json')));
  await check('decode existing APK image', () async {
    final data = await rootBundle.load('assets/logo.png');
    final frame = await (await ui.instantiateImageCodec(data.buffer.asUint8List())).getNextFrame();
    return '${frame.image.width}x${frame.image.height}';
  });
  await check('read missing asset', () async => rootBundle.loadString('assets/not_in_apk.json'));
  await check('AssetManifest lists APK assets only', () async {
    final m = await AssetManifest.loadFromAssetBundle(rootBundle);
    return m.listAssets().where((a) => a.startsWith('assets/')).toList();
  });
  await check('decode image bytes embedded in the module', () async {
    final frame = await (await ui.instantiateImageCodec(embeddedPng)).getNextFrame();
    return '${frame.image.width}x${frame.image.height}';
  });
  await check('register a font at runtime (FontLoader, bytes from APK font)', () async {
    final loader = FontLoader('PatchFont')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await loader.load();
    return 'loaded';
  });
  await check('runtime asset override via host overlay map', () {
    FeatureSlots.assetOverrides['assets/probe_added.json'] = utf8.encode('{"ok": true}');
    return FeatureSlots.assetOverrides.keys.toList();
  });
  return r;
}
