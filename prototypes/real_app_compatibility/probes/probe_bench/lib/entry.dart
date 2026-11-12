// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

// pkg_rename:keep
import 'package:compat_suites/compat_suites.dart' as aot;
import 'package:compat_suites/compat_suites.dart' as interpreted;

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'bench', 'run': run};

const warmup = 3;
const runs = 25;

Map<String, num> stats(List<double> v) {
  final s = [...v]..sort();
  double pct(double p) => s[((p / 100) * (s.length - 1)).round()];
  return {'n': s.length, 'avg': s.reduce((a, b) => a + b) / s.length, 'median': pct(50), 'p90': pct(90), 'p99': pct(99), 'worst': s.last};
}

Future<(Map<String, num>, int)> measure(FutureOr<int> Function() k) async {
  var check = 0;
  for (var i = 0; i < warmup; i++) {
    check = await k();
  }
  final times = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    check = await k();
    times.add(sw.elapsedMicroseconds / 1000);
    await Future<void>.delayed(Duration.zero); // let frames run between samples
  }
  return (stats(times), check);
}

Future<Map<String, Object?>> run() async {
  final out = <String, Object?>{};
  final a = aot.benchKernels();
  final i = interpreted.benchKernels();
  for (final name in a.keys) {
    final (sa, ca) = await measure(a[name]!);
    final (si, ci) = await measure(i[name]!);
    out[name] = {
      'aot_ms': sa,
      'interpreted_ms': si,
      'slowdown_median': (si['median']! / sa['median']!),
      'checksums_equal': ca == ci,
    };
  }
  return out;
}
