// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Shot 2 device app. The test cases (lib/cases.dart, lib/src/) are copied from ../cases/v1 by
// run_shot2.sh; this file is the same in the store build and in the patched version.
//
// Every start prints machine-readable lines to logcat (tag "flutter"):
//   [shot2] start   status=<status> patch=<id|none> pending=<id|none> init_ms=<n> timings=<...>
//   [shot2] case    <name>\t<value>          one line per case, same format as the local run
//   [shot2] cases_done
//   [shot2] bench   <name>\t<median us>      45 s after the first frame (after the update check)
//   [shot2] bench_done

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

import 'cases.dart';
import 'src/bench.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sw = Stopwatch()..start();
  await FlutterOta.initialize();
  final initMs = sw.elapsedMilliseconds;

  final lines = <String>[
    '[shot2] start status=${FlutterOta.status.name} patch=${FlutterOta.activePatchId ?? 'none'} '
        'pending=${FlutterOta.pendingPatchId ?? 'none'} init_ms=$initMs '
        'timings=${FlutterOta.lastStartupTimings ?? 'none'}',
  ];
  for (final l in await runAll()) {
    lines.add('[shot2] case $l');
  }
  lines.add('[shot2] cases_done');
  for (final l in lines) {
    print(l);
  }
  runApp(Shot2App(lines));

  // The bench runs on the UI isolate, so it waits until the start is confirmed and the update
  // check has run (stable period 10 s after the first frame).
  Timer(const Duration(seconds: 45), () {
    runBench(out: (l) => print('[shot2] bench $l'));
    print('[shot2] bench_done');
  });
}

class Shot2App extends StatelessWidget {
  const Shot2App(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Shot 2')),
      body: ListView(
        children: [for (final l in lines) Text(l.replaceFirst('[shot2] ', ''), style: const TextStyle(fontSize: 11))],
      ),
    ),
  );
}
