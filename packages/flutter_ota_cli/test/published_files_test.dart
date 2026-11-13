// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// The owner-side toolchain bundle builder (lib/owner.dart, lib/src/owner/) is excluded from the
// published package by .pubignore. If published code imported it, `dart pub global activate
// flutter_ota_cli` would fail to compile (this happened in 0.2.0-alpha).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

bool _isOwnerFile(String rel) => rel == p.join('lib', 'owner.dart') || p.isWithin(p.join('lib', 'src', 'owner'), rel);

void main() {
  test('published code never imports the owner-side bundle builder', () {
    final offenders = <String>[];
    for (final dir in ['lib', 'bin']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        final rel = p.relative(f.path);
        if (!rel.endsWith('.dart') || _isOwnerFile(rel)) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (RegExp(r'''^\s*(import|export)\s+['"]''').hasMatch(l) &&
              (l.contains('owner/') || l.contains('flutter_ota_cli/owner.dart'))) {
            offenders.add('$rel:${i + 1}: ${l.trim()}');
          }
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('.pubignore still excludes exactly the owner-side files this test assumes', () {
    final ignore = File('.pubignore').readAsLinesSync().map((l) => l.trim()).toSet();
    expect(ignore, containsAll(['/lib/owner.dart', '/lib/src/owner/']));
  });
}
