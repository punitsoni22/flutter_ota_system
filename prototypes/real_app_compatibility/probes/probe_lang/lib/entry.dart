// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// pkg_rename:keep
import 'package:compat_suites/compat_suites.dart' as aot;
import 'package:compat_suites/compat_suites.dart' as interpreted;

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'lang', 'run': run};

Future<Map<String, Object?>> run() async {
  final i = await interpreted.runLanguageSuite();
  final a = await aot.runLanguageSuite();
  return {
    for (final k in i.keys)
      k: {
        'interpreted': i[k],
        'aot': a[k],
        'executes': !i[k]!.startsWith('ERROR'),
        'matches_aot': i[k] == a[k],
      },
  };
}
