// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Analysis tool (Linux only, not a security boundary): reads a bytecode module with the pinned
// upstream dart2bytecode reader (Component.read) and prints the upstream disassembly
// (Component.toString). Used to locate the function and instruction behind a modified byte.
//
//   dart --packages=<dart-src>/.dart_tool/package_config.json bc_inspect.dart <module.bc>

import 'dart:io';

import 'package:dart2bytecode/bytecode_serialization.dart' show BufferedReader, LinkReader;
import 'package:dart2bytecode/declarations.dart' show Component;

void main(List<String> args) {
  final bytes = File(args.first).readAsBytesSync();
  try {
    final component = Component.read(BufferedReader(LinkReader(), bytes));
    if (args.length > 1 && args[1] == '--functions') {
      // One block per function, so a function the upstream disassembler cannot decode is named.
      for (final lib in component.libraries) {
        for (final cls in lib.classes) {
          for (final f in cls.members.functions) {
            final where = '${lib.importUri}::${cls.name}::${f.name}';
            try {
              stdout.writeln('== $where\n${f.code}');
            } catch (e) {
              stdout.writeln('== $where\nDISASSEMBLY_FAILED: $e');
            }
          }
        }
      }
      return;
    }
    stdout.write(component.toString());
  } catch (e, s) {
    stdout.writeln('READ_ERROR: $e');
    stdout.writeln(s.toString().split('\n').take(6).join('\n'));
    exitCode = 1;
  }
}
