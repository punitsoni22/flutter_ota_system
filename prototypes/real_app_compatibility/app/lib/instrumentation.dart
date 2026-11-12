// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Test instrumentation: results are written as JSON files under the app's external files
// directory and pulled by the device scripts (logcat truncates long lines).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_core/app_core.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_state/shared_state.dart';

import 'host_ui.dart';
import 'patch_runtime.dart';

String readMode() {
  final f = File('${inboxDir.path}/mode');
  return f.existsSync() ? f.readAsStringSync().trim() : 'home';
}

Future<void> writeResult(String name, Object? value) async {
  await resultsDir.create(recursive: true);
  final f = File('${resultsDir.path}/$name.json');
  await f.writeAsString(JsonEncoder.withIndent('  ', (o) => o.toString()).convert(value), flush: true);
  log('RESULT $name');
}

Map<String, Object?> memorySnapshot() {
  final status = File('/proc/self/status').readAsLinesSync();
  int? kb(String key) {
    final line = status.firstWhere((l) => l.startsWith('$key:'), orElse: () => '');
    return line.isEmpty ? null : int.parse(line.split(RegExp(r'\s+'))[1]);
  }

  return {'VmRSS_kb': kb('VmRSS'), 'VmHWM_kb': kb('VmHWM'), 'dart_current_rss': ProcessInfo.currentRss, 'dart_max_rss': ProcessInfo.maxRss};
}

Map<String, num> stats(List<double> v) {
  if (v.isEmpty) return {'count': 0};
  final s = [...v]..sort();
  double pct(double p) => s[((p / 100) * (s.length - 1)).round()];
  return {
    'count': s.length,
    'avg': s.reduce((a, b) => a + b) / s.length,
    'median': pct(50),
    'p90': pct(90),
    'p99': pct(99),
    'worst': s.last,
  };
}

/// All visible text, plus the on-screen centre (physical pixels) of keyed tap targets.
Map<String, Object?> dumpUi() {
  final texts = <String>[];
  final targets = <String, List<int>>{};
  final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
  void visit(Element e) {
    final w = e.widget;
    if (w is Text) texts.add(w.data ?? w.textSpan?.toPlainText() ?? '');
    final key = w.key;
    if (key is ValueKey<String> && (key.value.startsWith('row-') || key.value.startsWith('nav-'))) {
      final r = e.renderObject;
      if (r is RenderBox && r.hasSize && r.attached) {
        final c = r.localToGlobal(r.size.center(Offset.zero));
        targets[key.value] = [(c.dx * dpr).round(), (c.dy * dpr).round()];
      }
    }
    e.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return {
    'route_stack_top': _topRoute(),
    'texts': texts,
    'tap_targets': targets,
    'slots': FeatureSlots.sources,
    'cart': AppState.instance.cart.length,
  };
}

String? _topRoute() {
  String? name;
  HostNavigation.key.currentState?.popUntil((r) {
    name = r.settings.name ?? (r.isFirst ? 'home' : r.runtimeType.toString());
    return true;
  });
  return name;
}

class FrameCollector {
  final timings = <ui.FrameTiming>[];
  void _cb(List<ui.FrameTiming> t) => timings.addAll(t);
  void start() => SchedulerBinding.instance.addTimingsCallback(_cb);
  Map<String, Object?> stop() {
    SchedulerBinding.instance.removeTimingsCallback(_cb);
    final refresh = ui.PlatformDispatcher.instance.views.first.display.refreshRate;
    final budget = 1000 / refresh;
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = timings.map((t) => ms(t.buildDuration)).toList();
    final raster = timings.map((t) => ms(t.rasterDuration)).toList();
    final total = timings.map((t) => ms(t.totalSpan)).toList();
    int over(double b) => timings.where((t) => ms(t.buildDuration) > b || ms(t.rasterDuration) > b).length;
    return {
      'refresh_hz': refresh,
      'budget_ms': budget,
      'frames': timings.length,
      'build_ms': stats(build),
      'raster_ms': stats(raster),
      'total_span_ms': stats(total),
      'missed_budget_frames': over(budget),
      'missed_16ms_frames': over(1000 / 60),
    };
  }
}

/// Mode-driven test driver. Mode comes from inbox/mode, e.g. "home", "catalog", "profile",
/// "feed:25" (open the feed and record frame timings for 25 s).
class Driver {
  Driver(this.mode);
  final String mode;
  int _dumps = 0;

  Future<void> run() async {
    final name = mode.split(':').first;
    if (name == 'catalog' || name == 'profile') {
      openRoute(name);
    }
    if (name == 'feed') {
      final seconds = int.tryParse(mode.split(':').elementAtOrNull(1) ?? '') ?? 20;
      final c = FrameCollector()..start();
      openRoute('feed');
      log('FEED_RECORDING ${seconds}s');
      Timer(Duration(seconds: seconds), () => writeResult('frames', {'slot': FeatureSlots.sources['catalog'], ...c.stop()}));
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await _dump();
    // A DUMP marker pushed by the script asks for another snapshot (after taps, etc.).
    Timer.periodic(const Duration(milliseconds: 400), (_) async {
      final f = File('${inboxDir.path}/DUMP');
      if (f.existsSync()) {
        f.deleteSync();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _dump();
      }
    });
  }

  Future<void> _dump() async {
    _dumps++;
    await writeResult('ui_$_dumps', {...dumpUi(), 'memory': memorySnapshot()});
  }
}
