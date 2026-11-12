// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:greeting/greeting.dart' as baseline;

import 'patch_loader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final patch = await bootPatch();
  final text = patch == null ? baseline.greeting() : patch.greeting();
  final source = patch == null ? 'baseline (AOT, libapp.so)' : 'patch #${patch.patchNumber} (bytecode, interpreter)';
  log('greeting="$text" source=$source');
  runApp(_App(text: text, source: source));
  if (patch != null) Timer(const Duration(seconds: 3), confirmBoot);
}

class _App extends StatelessWidget {
  const _App({required this.text, required this.source});
  final String text;
  final String source;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, color: Color(0xFF000000))),
              const SizedBox(height: 16),
              Text('source: $source', style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
              Text('app: $appId', style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
              Text('baseline: $baselineId', style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
            ],
          ),
        ),
      ),
    ),
  );
}
