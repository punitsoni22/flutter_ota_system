// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app/cases.dart';
import 'package:app/src/bench.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'bench') {
    runBench(out: (l) => print(l.startsWith('sink\t') ? l : 'bench\t$l'));
    return;
  }
  for (final line in await runAll()) {
    print(line);
  }
}
