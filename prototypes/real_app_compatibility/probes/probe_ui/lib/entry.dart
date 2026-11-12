// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'ui', 'run': run};

Future<Map<String, Object?>> run() async {
  final obs = <String, Object?>{};
  final done = Completer<void>();
  final nav = HostNavigation.key.currentState!;
  obs['host Navigator reachable (NavigatorState)'] = nav.runtimeType.toString();
  unawaited(nav.push(PageRouteBuilder<void>(
    settings: const RouteSettings(name: 'probe-ui'),
    pageBuilder: (c, _, _) => ProbePage(obs: obs, done: done),
  )));
  try {
    await done.future.timeout(const Duration(seconds: 15));
  } on TimeoutException {
    obs['TIMEOUT'] = true;
  }
  nav.pop();
  return obs;
}

class ModulePainter extends CustomPainter {
  ModulePainter(this.obs);
  final Map<String, Object?> obs;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF3366FF));
    obs['CustomPainter.paint called'] = true;
  }

  @override
  bool shouldRepaint(ModulePainter old) => false;
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key, required this.obs, required this.done});
  final Map<String, Object?> obs;
  final Completer<void> done;
  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  final _stream = StreamController<int>();
  final _streamSeen = <String>[];
  final _futureStates = <String>[];
  StateSetter? _setter;
  int _taps = 0;
  int _builds = 0;
  int _animTicks = 0;

  Map<String, Object?> get obs => widget.obs;

  @override
  void initState() {
    super.initState();
    obs['State.initState'] = true;
    _anim.addListener(() => _animTicks++);
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed) _afterAnimation();
    });
    _anim.forward();
  }

  Future<void> _afterAnimation() async {
    obs['AnimationController completed, ticks'] = _animTicks;
    for (final v in [1, 2, 3]) {
      _stream.add(v);
    }
    _setter?.call(() => _taps++);
    _setter?.call(() => _taps++);
    setState(() {});
    // Nested navigation from module code with the module's own BuildContext.
    final nested = Navigator.of(context).push(PageRouteBuilder<String>(
      pageBuilder: (c, _, _) => const Center(child: Text('nested route')),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Navigator.of(context).pop('popped-with-result');
    obs['Navigator.push/pop result'] = await nested;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      obs['postFrameCallback'] = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
    obs['StreamBuilder saw'] = _streamSeen;
    obs['FutureBuilder states'] = _futureStates;
    obs['StatefulBuilder/StateSetter taps'] = _taps;
    obs['build() calls'] = _builds;
    if (!widget.done.isCompleted) widget.done.complete();
  }

  @override
  void dispose() {
    _anim.dispose();
    _stream.close();
    obs['State.dispose'] = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _builds++;
    obs['BuildContext.mounted'] = context.mounted;
    obs['MediaQuery size > 0'] = MediaQuery.sizeOf(context).width > 0;
    obs['Directionality'] = Directionality.of(context).name;
    return ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: SafeArea(
        child: Column(children: [
          const Text('probe_ui (bytecode widgets)'),
          AnimatedBuilder(
            animation: _anim,
            builder: (_, _) => Opacity(opacity: _anim.value, child: Text('anim ${_anim.value.toStringAsFixed(2)}')),
          ),
          FutureBuilder<String>(
            future: Future<String>.delayed(const Duration(milliseconds: 100), () => 'loaded'),
            builder: (_, s) {
              _futureStates.add('${s.connectionState.name}:${s.data}');
              return Text('future ${s.data}');
            },
          ),
          StreamBuilder<int>(
            stream: _stream.stream,
            builder: (_, s) {
              if (s.hasData) _streamSeen.add('${s.data}');
              return Text('stream ${s.data}');
            },
          ),
          StatefulBuilder(builder: (ctx, setter) {
            _setter = setter;
            return Text('taps $_taps');
          }),
          LayoutBuilder(builder: (ctx, c) {
            obs['LayoutBuilder constraints'] = c.maxWidth.isFinite;
            return const SizedBox(height: 10);
          }),
          SizedBox(width: 40, height: 20, child: CustomPaint(painter: ModulePainter(obs))),
        ]),
      ),
    );
  }
}
