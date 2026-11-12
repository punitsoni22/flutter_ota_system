// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app_core/app_core.dart';
import 'package:compat_suites/compat_suites.dart';
import 'package:patchable_utils/patchable_utils.dart';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'multi_a', 'run': run};

class PriceGreeter extends Greeter {
  @override
  String greet(String name) => 'module A greets $name, price ${formatPrice(39900)}';
}

class ACounter {
  int value = 0;
  int increment() => ++value;
}

Future<Map<String, Object?>> run() async {
  PatchRegistry.register('a.greeter', PriceGreeter());
  PatchRegistry.register('a.counter', ACounter());
  PatchRegistry.register('a.fn', (String s) => 'A:${s.toUpperCase()}');
  return {'registered': PatchRegistry.names.toList()};
}
