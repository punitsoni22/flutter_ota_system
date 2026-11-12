// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Experiment modules ("probes") pushed to inbox/probes/*.otp. Each file is deleted BEFORE it is
// loaded, so a probe that crashes the process cannot cause a crash loop.

import 'dart:io';
import 'dart:typed_data';

import 'package:dynamic_modules/dynamic_modules.dart' as dm;

import 'instrumentation.dart';
import 'patch_runtime.dart';

Future<void> runProbes() async {
  final dir = Directory('${inboxDir.path}/probes');
  if (!dir.existsSync()) return;
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.otp')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final file = f.uri.pathSegments.last.replaceAll('.otp', '');
    final bytes = f.readAsBytesSync();
    f.deleteSync();
    final out = <String, Object?>{'file': file};
    try {
      final p = parsePatch(bytes, kind: 'probe');
      out['name'] = p.manifest['name'];
      out['module_bytes'] = p.module.length;
      log('PROBE $file loading');
      final sw = Stopwatch()..start();
      final Object? r;
      try {
        r = await dm.loadModuleFromBytes(Uint8List.fromList(p.module));
      } catch (e) {
        out['status'] = 'LOAD_ERROR';
        out['error'] = '${e.runtimeType}: $e';
        continue;
      }
      out['load_ms'] = sw.elapsedMicroseconds / 1000;
      if (r is! Map || r['run'] is! Future<Object?> Function()) {
        out['status'] = 'BAD_ENTRY';
        out['error'] = 'entry returned ${r.runtimeType}';
        continue;
      }
      try {
        out['result'] = await (r['run']! as Future<Object?> Function())().timeout(const Duration(seconds: 180));
        out['status'] = 'RAN';
      } catch (e, s) {
        out['status'] = 'RUN_ERROR';
        out['error'] = '${e.runtimeType}: $e';
        out['stack'] = s.toString().split('\n').take(8).toList();
      }
    } on InvalidPatch catch (e) {
      out['status'] = 'REJECTED';
      out['error'] = e.toString();
    } finally {
      out['memory_after'] = memorySnapshot();
      log('PROBE $file ${out['status']}');
      await writeResult('probe_$file', out);
    }
  }
  log('PROBES_DONE');
}
