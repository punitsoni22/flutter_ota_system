// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:feature_catalog/feature_catalog.dart';
import 'package:feature_profile/feature_profile.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_state/shared_state.dart';
import 'package:user_service/user_service.dart';

import 'host_services.dart';
import 'host_ui.dart';
import 'instrumentation.dart';
import 'patch_runtime.dart';
import 'probe_runner.dart';

final _sinceMain = Stopwatch();

/// Watches the unconfirmed window after a patched start. An error there counts as a failed start
/// and the slots fall back to the AOT implementations immediately (no restart needed).
class Health {
  static BootResult? boot;
  static bool confirmed = false;
  static bool failed = false;
  static final PatchStore store = PatchStore();
  static final ValueNotifier<int> slotsChanged = ValueNotifier(0);

  static void reportError(String what) {
    log('ERROR $what');
    final b = boot;
    if (b == null || confirmed || failed) return;
    failed = true;
    store.recordFailure(b.patch.id, 'runtime error before confirmation: $what');
    // Already counted: the next start must not count this attempt again.
    if (store.attempt.existsSync()) store.attempt.deleteSync();
    FeatureSlots.catalog = CatalogFeatureImpl();
    FeatureSlots.profile = ProfileFeatureImpl();
    FeatureSlots.assetOverrides.clear();
    FeatureSlots.sources.updateAll((_, _) => 'aot (live fallback)');
    slotsChanged.value++;
    log('LIVE_FALLBACK slots restored to AOT implementations');
  }
}

Future<void> main() async {
  _sinceMain.start();
  runZonedGuarded(_boot, (e, s) => Health.reportError('uncaught ${e.runtimeType}: $e'));
}

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    Health.reportError('FlutterError: ${details.exceptionAsString()}');
  };
  final mode = readMode();
  log('START mode=$mode app=$appId baseline=$baselineId');
  await setUpHostServices();
  FeatureSlots.catalog = CatalogFeatureImpl();
  FeatureSlots.profile = ProfileFeatureImpl();

  final exit = await lastExitInfo();
  log('LAST_EXIT ${exit ?? 'none'}');
  final boot = await Health.store.boot(exit);
  Health.boot = boot;
  if (boot != null) {
    final applied = FeatureSlots.apply(boot.overrides, 'patch ${boot.patch.label}');
    log('APPLIED ${applied.join(', ')}');
  }
  final bootMs = _sinceMain.elapsedMicroseconds / 1000;

  runApp(HostApp(slotsChanged: Health.slotsChanged));
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  final firstFrameMs = _sinceMain.elapsedMicroseconds / 1000;
  log('FIRST_FRAME main_to_first_frame_ms=${firstFrameMs.toStringAsFixed(1)} '
      'boot_ms=${bootMs.toStringAsFixed(1)} module_load_ms=${boot?.loadMs.toStringAsFixed(1) ?? '-'}');
  await writeResult('boot', {
    'patch': boot?.patch.label,
    'patch_id': boot?.patch.id,
    'module_bytes': boot?.patch.module.length,
    'module_load_ms': boot?.loadMs,
    'boot_ms': bootMs,
    'main_to_first_frame_ms': firstFrameMs,
    'slots': FeatureSlots.sources,
    'last_exit': exit?.toString(),
    'memory': memorySnapshot(),
  });

  if (boot != null) {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!Health.failed) {
      Health.store.confirm(boot.patch.id);
      Health.confirmed = true;
    }
  }
  // Probes and the test driver start only after the start was confirmed (or when no patch runs),
  // so an experiment can never count against the active patch.
  await Driver(mode).run();
  await runProbes();
}

Future<void> setUpHostServices() async {
  final locator = ServiceLocator.instance;
  locator.register<Logger>(Logger('host'));
  locator.register<AppConfig>(const AppConfig(environment: 'prototype', apiBase: 'https://example.invalid'));
  locator.register<KeyValueStore>(PrefsStore());
  locator.register<UserService>(UserService());
  log('host AppState token=${AppState.instance.token} createdAt=${AppState.instance.createdAt}');
  eventBus.events.listen((e) => globalLog.add('host saw $e'));
  locator.get<UserService>().login('u1', 'Asha');
  // Let the broadcast stream deliver the login event.
  await Future<void>.delayed(Duration.zero);
}
