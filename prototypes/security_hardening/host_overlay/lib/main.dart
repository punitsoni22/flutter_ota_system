// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 3 host boot (overlay on the Phase 2 host). Differences from Phase 2:
//  - SecureStore (signed container v2, isolated verification before activation);
//  - no unsigned probe loading: the module loader is only reached through verification;
//  - inbox/verify/*.otp: verify-only requests for the security corpus (never activated).

import 'dart:async';
import 'dart:io';

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
// Keeps the isolated verifier's entry point in the AOT snapshot.
export 'verifier_main.dart' show verifierMain;

final _sinceMain = Stopwatch();

class Health {
  static BootResult? boot;
  static bool confirmed = false;
  static bool failed = false;
  static final SecureStore store = SecureStore();
  static final ValueNotifier<int> slotsChanged = ValueNotifier(0);

  static void reportError(String what) {
    log('ERROR $what');
    final b = boot;
    if (b == null || confirmed || failed) return;
    failed = true;
    store.recordFailure(b.id, 'runtime error before confirmation: $what');
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
  log('START mode=$mode app=$appId release=$baselineId pid=$pid');
  await setUpHostServices();
  FeatureSlots.catalog = CatalogFeatureImpl();
  FeatureSlots.profile = ProfileFeatureImpl();

  final exit = await lastExitInfo();
  log('LAST_EXIT ${exit ?? 'none'}');
  final boot = await Health.store.boot(exit);
  Health.boot = boot;
  if (boot != null) {
    final applied = FeatureSlots.apply(boot.overrides, 'patch ${boot.label}');
    log('APPLIED ${applied.join(', ')}');
  }
  final bootMs = _sinceMain.elapsedMicroseconds / 1000;
  runApp(HostApp(slotsChanged: Health.slotsChanged));
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  final firstFrameMs = _sinceMain.elapsedMicroseconds / 1000;
  log('FIRST_FRAME main_to_first_frame_ms=${firstFrameMs.toStringAsFixed(1)} boot_ms=${bootMs.toStringAsFixed(1)}');
  await writeResult('boot', {
    'pid': pid,
    'patch': boot?.label,
    'patch_id': boot?.id,
    'boot_ms': bootMs,
    'main_to_first_frame_ms': firstFrameMs,
    'slots': FeatureSlots.sources,
    'last_exit': exit?.toString(),
  });
  if (boot != null) {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!Health.failed) {
      Health.store.confirm(boot.id);
      Health.confirmed = true;
    }
  }
  await Driver(mode).run();
  await _verifyOnlyRequests();
}

/// Security corpus: each inbox/verify/*.otp goes through the full verification (crypto, then the
/// isolated load) and is NEVER activated. The main process must survive every file.
Future<void> _verifyOnlyRequests() async {
  final dir = Directory('${inboxDir.path}/verify');
  if (!dir.existsSync()) return;
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.otp')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final results = <String, Object?>{};
  for (final f in files) {
    final name = f.uri.pathSegments.last.replaceAll('.otp', '');
    final r = await Health.store.verifyOnly(f);
    results[name] = r;
    log('VERIFY_ONLY $name crypto=${r['crypto']} isolated=${r['status']} ${r['code'] ?? ''}');
    await writeResult('verify_results', {'pid': pid, 'results': results});
  }
  log('VERIFY_ONLY_DONE ${files.length} files, main process pid=$pid alive');
}

Future<void> setUpHostServices() async {
  final locator = ServiceLocator.instance;
  locator.register<Logger>(Logger('host'));
  locator.register<AppConfig>(const AppConfig(environment: 'prototype', apiBase: 'https://example.invalid'));
  locator.register<KeyValueStore>(PrefsStore());
  locator.register<UserService>(UserService());
  log('host AppState token=${AppState.instance.token}');
  eventBus.events.listen((e) => globalLog.add('host saw $e'));
  locator.get<UserService>().login('u1', 'Asha');
  await Future<void>.delayed(Duration.zero);
}
