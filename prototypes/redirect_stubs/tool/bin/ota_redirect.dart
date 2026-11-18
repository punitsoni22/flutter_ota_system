// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// ota_redirect: Shot 1 spike tool for function-level OTA patches.
//
//   dart run bin/ota_redirect.dart instrument <package-dir> [--no-pragma]
//       Rewrites <package-dir>/lib in place for a store build and writes ota_manifest.json.
//
//   dart run bin/ota_redirect.dart patch <v1-dir> <v2-dir> <out-dir> [options]
//       Local simulation (default): writes <out-dir>/lib/ota_patch/*.dart into the instrumented
//       app <out-dir> and reads <out-dir>/ota_manifest.json.
//       --module <name>    device build: write a standalone module package to <out-dir> with an
//                          entry point (lib/entry.dart) that fills the slots when loaded
//       --manifest <path>  the store build's ota_manifest.json (default: <out-dir>/ota_manifest.json)
//       --critical         whole-app copy (level 4; local simulation only for now)
//       Always writes <out-dir>/ota_patch_report.json (level, metrics, decisions).

import 'dart:convert';
import 'dart:io';

import 'package:ota_redirect/src/instrument.dart';
import 'package:ota_redirect/src/model.dart';
import 'package:ota_redirect/src/patch.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: instrument <dir> [--no-pragma] | patch <v1> <v2> <instrumented>');
    exit(64);
  }
  switch (args.first) {
    case 'instrument':
      final idx = await PackageIndex.load(args[1]);
      final ins = Instrumenter(idx,
          slotPragma: !args.contains('--no-pragma'),
          outline: !args.contains('--inline-slow-path'),
          skipLeaves: args.contains('--skip-leaves'));
      ins.run();
      print('instrumented ${idx.units.length} files: ${ins.guards} guards, '
          '${ins.initSlots} initializer slots, ${ins.leaves.length} tiny leaves without a check, '
          '${ins.supers.length} super helpers, ${ins.accessors.length} private accessors');
    case 'patch':
      final v1 = await PackageIndex.load(args[1]);
      final v2 = await PackageIndex.load(args[2]);
      String? opt(String name) {
        final i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
      }

      final manifestPath = opt('--manifest') ?? p.join(args[3], 'ota_manifest.json');
      final manifest =
          (jsonDecode(File(manifestPath).readAsStringSync()) as Map).cast<String, Object?>();
      final plan = Planner(v1, v2, manifest, critical: args.contains('--critical'))..plan();
      PatchEmitter(plan, args[3], moduleName: opt('--module')).emit();
      final m = plan.metrics();
      print('PATCH LEVEL ${m['level']}: ${m['files_changed']} files, +${m['lines_added']}/'
          '-${m['lines_removed']} lines -> ${m['interpreted_functions']} functions interpreted, '
          '${m['copied_classes']} class copies, ${m['side_fields']} side fields, '
          '${m['repointed']} re-pointed');
      for (final e in plan.report.entries) {
        final items = e.value.toSet();
        if (items.isEmpty || e.key == 'level') continue;
        print('${e.key}: ${items.length}');
        for (final line in items) {
          print('  $line');
        }
      }
    default:
      stderr.writeln('unknown command ${args.first}');
      exit(64);
  }
}
