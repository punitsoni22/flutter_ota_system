// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Code run in a background isolate (known risk H4: slots are per isolate).

import 'dart:isolate';

int heavy(int n) => n * n;

Future<int> inIsolate(int n) => Isolate.run(() => heavy(n));

/// A top-level function as the isolate body (what `compute()` in Flutter also does).
Future<int> inIsolateTearOff() => Isolate.run(_heavyOf3);

int _heavyOf3() => heavy(3);

/// A long-lived isolate started with `Isolate.spawn` (background workers, push handlers).
Future<int> inIsolateSpawn(int n) async {
  final port = ReceivePort();
  await Isolate.spawn(_spawnEntry, [port.sendPort, n]);
  return await port.first as int;
}

void _spawnEntry(List<Object> args) => (args[0] as SendPort).send(heavy(args[1] as int));
