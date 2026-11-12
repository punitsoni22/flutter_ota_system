// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// FlutterOta: the developer-facing facade of the bytecode runtime (Phase 4 runtime contract).
// Experimental alpha. Android arm64 only, with the Flutter OTA System toolchain.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'bytecode/config.dart';
import 'bytecode/module_entry.dart';
import 'bytecode/patch_store.dart';
import 'bytecode/runtime_platform.dart';
import 'bytecode/update_api.dart';
// Imported so the verifier entry point is part of every app that uses the SDK (see that file).
// ignore: unused_import
import 'bytecode/verifier_main.dart';
import 'models.dart';
import 'patch_id.dart';
import 'security/security.dart';
import 'transport.dart';

export 'bytecode/module_entry.dart' show FlutterOtaModuleLoader;

/// What the bytecode runtime is doing in this app start.
enum FlutterOtaStatus {
  /// [FlutterOta.initialize] has not finished yet.
  notInitialized,

  /// OTA is off for this build or start; see [FlutterOta.disabledReason]. The store code runs.
  disabled,

  /// OTA is on, and no patch runs: the store code runs.
  storeCode,

  /// A verified patch is loaded; its features are used.
  patched,
}

/// The patch loaded in this app start.
class FlutterOtaPatchInfo {
  const FlutterOtaPatchInfo({required this.patchId, required this.sequence, required this.state, this.serverNumber});

  /// The patch's id from its signed manifest (a UUID).
  final String patchId;

  /// The patch's signed sequence number (higher is newer).
  final int sequence;

  /// Crash-state-machine state, e.g. `PROBATIONARY` (not yet confirmed) or `ACTIVE`.
  final String state;

  /// The patch number on the server, if known.
  final int? serverNumber;

  @override
  String toString() => 'patch #$sequence $patchId ($state)';
}

/// How long the parts of [FlutterOta.initialize] took in this start.
class FlutterOtaStartupTimings {
  const FlutterOtaStartupTimings({
    required this.total,
    this.native = Duration.zero,
    this.libappHash = Duration.zero,
    this.verification = Duration.zero,
    this.moduleLoad = Duration.zero,
  });

  /// The whole [FlutterOta.initialize] call.
  final Duration total;

  /// Native calls: storage path, app version and (when needed) the last exit reason.
  final Duration native;

  /// Hashing the store `libapp.so` (cached natively after the first start of an install).
  final Duration libappHash;

  /// Verifying the stored patch: container, manifest, certificates, signature, module SHA-256.
  final Duration verification;

  /// Loading the module and running its entry point.
  final Duration moduleLoad;

  static String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

  @override
  String toString() =>
      'total_ms=${_ms(total)} native_ms=${_ms(native)} libapp_hash_ms=${_ms(libappHash)} '
      'verify_ms=${_ms(verification)} module_load_ms=${_ms(moduleLoad)}';
}

/// Flutter OTA System bytecode runtime (experimental alpha, Android arm64 only).
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await FlutterOta.initialize();
///   runApp(const MyApp());
/// }
/// ```
///
/// - [initialize] never throws and makes no network request. It verifies and loads the stored
///   patch, if there is one.
/// - After the first frame and a stable period, the start is confirmed (crash protection) and an
///   update check runs in the background. A new patch is verified, also in a separate process,
///   and runs from the **next** app start. Running code is never swapped live.
/// - The app reaches patchable code only through [feature].
///
/// Configuration comes from the build: the flutter_ota CLI passes
/// `--dart-define=FLUTTER_OTA_CONFIG=...`. Without it (for example `flutter run`), OTA is
/// disabled and the store code runs.
abstract final class FlutterOta {
  static _Runtime? _rt;
  static Future<void>? _initializing;
  static FlutterOtaModuleLoader? _registeredLoader;
  static String? _disabledReason;

  /// Registers the module loader before [initialize].
  ///
  /// You normally never call this yourself. The Dart VM lets only a package named
  /// `dynamic_modules` call the module loader, so the SDK cannot do it. The flutter_ota CLI
  /// builds the app with a generated entry file (`-t lib/flutter_ota_main.g.dart`) that registers
  /// the loader and then calls your own `main()`, so `main.dart` stays unchanged.
  ///
  /// [loader] must be a top-level or static function annotated `@pragma('vm:entry-point')`: the
  /// separate verifier process finds it by name (a callback handle). A closure is accepted for
  /// loading, but then no new patch can be verified (status UNAVAILABLE) and none is activated.
  static void registerModuleLoader(FlutterOtaModuleLoader loader) => _registeredLoader = loader;

  /// Starts the runtime. Call once in `main()`, before `runApp`. Never throws.
  ///
  /// [moduleLoader] overrides [registerModuleLoader]. [stablePeriod] is how long the app must run
  /// after its first frame before the start of a new patch counts as successful.
  /// [checkForUpdates] runs the background update check after that period.
  static Future<void> initialize({
    FlutterOtaModuleLoader? moduleLoader,
    Duration stablePeriod = const Duration(seconds: 10),
    bool checkForUpdates = true,
  }) => _initializing ??= _initialize(moduleLoader ?? _registeredLoader, stablePeriod, checkForUpdates);

  static Future<void> _initialize(FlutterOtaModuleLoader? loader, Duration stablePeriod, bool check) async {
    final o = _overrides;
    final log = o?.log ?? _printLog;
    try {
      const define = String.fromEnvironment('FLUTTER_OTA_CONFIG');
      final parsed = FlutterOtaConfig.parse(o?.configDefine ?? define);
      for (final w in parsed.warnings) {
        log('CONFIG_WARNING $w');
      }
      final config = parsed.config;
      if (config == null) return _disable(log, parsed.disabledReason!);
      if (!(o?.isAndroid ?? Platform.isAndroid)) return _disable(log, 'this runtime supports Android only');
      if (loader == null) {
        return _disable(log, 'no module loader registered (see FlutterOta.registerModuleLoader)');
      }
      final rt = _Runtime(config, loader, o?.platform ?? MethodChannelFlutterOtaPlatform(), log, o);
      _rt = rt;
      await rt.start();
      rt.afterFirstFrame(stablePeriod, check);
    } catch (e) {
      // Never throws: any internal problem means the store code runs.
      _rt?.registry.disable();
      _rt = null;
      _disable(log, 'start-up error (${e.runtimeType}: $e)');
    }
  }

  static void _disable(void Function(String) log, String reason) {
    _disabledReason = reason;
    log('DISABLED $reason; the store code runs');
  }

  /// Returns the active patch's implementation of feature [name] when it exists and is a [T];
  /// otherwise `aotFactory()` (the store code).
  ///
  /// [T] must be a **host-owned** type: [OtaFeature] or an abstract class from a shared package
  /// that is part of the store build. A patch carries renamed copies of feature packages, so a
  /// feature's own class is a different type inside a patch. A wrong type is logged and ignored;
  /// it never crashes.
  static T feature<T extends Object>(String name, T Function() aotFactory) {
    final rt = _rt;
    if (rt == null) return aotFactory();
    return rt.registry.resolve<T>(name, aotFactory);
  }

  /// An asset carried by the active patch, or null.
  static Uint8List? patchAsset(String key) => _rt?.assets[key];

  /// Current status.
  static FlutterOtaStatus get status {
    final rt = _rt;
    if (rt == null) return _disabledReason != null ? FlutterOtaStatus.disabled : FlutterOtaStatus.notInitialized;
    if (!rt.started) return FlutterOtaStatus.notInitialized;
    return rt.loaded != null && !rt.registry.disabled ? FlutterOtaStatus.patched : FlutterOtaStatus.storeCode;
  }

  /// True when OTA runs in this start (configured, Android, module loader present), whether or not
  /// a patch is loaded.
  static bool get isEnabled => _rt != null;

  /// Manifest id of the patch loaded in this start, or null (store code).
  static String? get activePatchId => activePatch?.patchId;

  /// Why OTA is disabled, or null.
  static String? get disabledReason => _disabledReason;

  /// The patch loaded in this start, or null.
  static FlutterOtaPatchInfo? get activePatch {
    final rt = _rt;
    final v = rt?.loaded;
    if (rt == null || v == null) return null;
    final id = v.manifest.patchId;
    return FlutterOtaPatchInfo(
      patchId: id,
      sequence: v.manifest.sequence,
      state: rt.store.stateOf(id),
      serverNumber: rt.store.serverRef(id)?.number,
    );
  }

  /// Manifest id of a verified patch that runs from the next start, or null.
  static String? get pendingPatchId => _rt?.store.pendingPatchId;

  /// Timings of this start's [initialize], or null if OTA is disabled.
  static FlutterOtaStartupTimings? get lastStartupTimings => _rt?.timings;

  /// Asks the server for a newer patch now and, if there is one, downloads and verifies it so it
  /// runs from the next start. Never throws. The automatic check after start-up uses the same
  /// code; calls made while a check runs share its result.
  static Future<UpdateResult> checkForUpdate() async {
    final rt = _rt;
    if (rt == null || !rt.started) {
      return UpdateResult(UpdateStatus.failed, message: _disabledReason ?? 'FlutterOta.initialize() not finished');
    }
    return rt.checkForUpdate();
  }

  // ---- testing -------------------------------------------------------------------------------

  static FlutterOtaTestOverrides? _testOverrides;

  // Always null in release builds, so the test seams cannot change a shipped app.
  static FlutterOtaTestOverrides? get _overrides => kReleaseMode ? null : _testOverrides;

  /// Unit tests only. Has no effect in release builds.
  @visibleForTesting
  static set debugOverrides(FlutterOtaTestOverrides? value) => _testOverrides = value;

  /// Unit tests only: forgets everything, as if the app restarted.
  @visibleForTesting
  static void debugReset() {
    _rt?.dispose();
    _rt = null;
    _initializing = null;
    _registeredLoader = null;
    _disabledReason = null;
  }

  /// Unit tests only: confirms the start now instead of after the first frame + stable period.
  @visibleForTesting
  static void debugConfirmStart() => _rt?.confirm();

  /// Unit tests only: the state of patch [patchId] in the store.
  @visibleForTesting
  static String? debugPatchState(String patchId) => _rt?.store.stateOf(patchId);
}

/// Unit-test seams of [FlutterOta]. Ignored in release builds.
@visibleForTesting
class FlutterOtaTestOverrides {
  const FlutterOtaTestOverrides({
    this.configDefine,
    this.platform,
    this.httpClient,
    this.isAndroid,
    this.arch,
    this.log,
    this.now,
    this.verifyTimeout,
  });

  final String? configDefine;
  final FlutterOtaPlatform? platform;
  final http.Client? httpClient;
  final bool? isAndroid;
  final String? arch;
  final void Function(String)? log;
  final DateTime Function()? now;
  final Duration? verifyTimeout;
}

void _printLog(String message) {
  // Visible in logcat (tag "flutter") in every build mode: the lead's device tests read it.
  // ignore: avoid_print
  print('[flutter_ota] $message');
}

class _Runtime {
  _Runtime(this.config, this.loader, this.platform, this.log, this.overrides)
    : registry = FeatureRegistry(log);

  final FlutterOtaConfig config;
  final FlutterOtaModuleLoader loader;
  final FlutterOtaPlatform platform;
  final void Function(String) log;
  final FlutterOtaTestOverrides? overrides;
  final FeatureRegistry registry;

  late PatchStore store;
  late NativeStartupInfo info;
  bool started = false;
  VerifiedPatch? loaded;
  Map<String, Uint8List> assets = const {};
  FlutterOtaStartupTimings? timings;
  bool _confirmed = false;
  bool _failed = false;
  Timer? _stableTimer;
  Future<String>? _libapp;
  Future<UpdateResult>? _inFlight;

  DateTime _now() => (overrides?.now ?? DateTime.now)().toUtc();

  Future<String> libappSha256() => _libapp ??= platform.libappSha256();

  CertificateTrust get trust => config.certificateTrust();

  // Direct (uncertified) keys are never trusted for dbc-v1: certificates are required.
  static final _noDirectKeys = Es256Verifier(const {});

  VerifiedPatch _verify(Uint8List bytes, DeviceSecurityState state, String libapp, {required bool reinstall}) =>
      verifyPatch(
        bytes,
        host: config.hostIdentity(libapp),
        keys: _noDirectKeys,
        state: state,
        now: _now(),
        reinstall: reinstall,
        trust: trust,
      );

  Future<void> start() async {
    final total = Stopwatch()..start();
    var nativeT = Duration.zero, hashT = Duration.zero, verifyT = Duration.zero, loadT = Duration.zero;
    final sw = Stopwatch()..start();
    info = await platform.startupInfo();
    store = PatchStore(Directory('${info.filesDir}/flutter_ota'), pid: pid, log: log, now: _now);
    store.open(config.releaseId);
    final hadSession = store.attempt.existsSync() || store.session.existsSync();
    final exit = hadSession ? await platform.lastExit() : null;
    nativeT = sw.elapsed;
    if (hadSession) log('LAST_EXIT ${exit ?? 'none'}');
    store.attributePreviousSession(exit);

    if (store.pendingPatchId != null || store.active.existsSync()) {
      sw.reset();
      final libapp = await libappSha256();
      hashT = sw.elapsed;
      sw.reset();
      store.activatePending((b, st) => _verify(b, st, libapp, reinstall: false));
      final v = store.verifyStored((b, st) => _verify(b, st, libapp, reinstall: true));
      verifyT = sw.elapsed;
      if (v != null) {
        final id = v.manifest.patchId;
        store.startSession(id);
        sw.reset();
        try {
          final entry = parseModuleEntry(await loader(Uint8List.fromList(v.module)));
          loadT = sw.elapsed;
          registry.install(entry);
          registry.onFactoryError = (name, e) => _patchError('feature "$name" factory threw ${e.runtimeType}');
          assets = Map.unmodifiable(entry.assets);
          loaded = v;
          log(
            'LOADED patch #${v.manifest.sequence} ${id.substring(0, 8)} features=${entry.features.keys.join(',')} '
            'in ${(loadT.inMicroseconds / 1000).toStringAsFixed(1)} ms',
          );
          _installErrorHooks();
        } catch (e) {
          loadT = sw.elapsed;
          store.abandonSession();
          log('MODULE_LOAD_FAILED ${e.runtimeType}: $e');
          store.recordFailure(id, 'module load/entry failed');
        }
      } else {
        log('NO_PATCH the store code runs');
      }
    } else {
      log('NO_PATCH the store code runs');
    }
    timings = FlutterOtaStartupTimings(
      total: total.elapsed,
      native: nativeT,
      libappHash: hashT,
      verification: verifyT,
      moduleLoad: loadT,
    );
    started = true;
    log('STARTUP $timings');
  }

  // ---- confirmation and errors ---------------------------------------------------------------

  void afterFirstFrame(Duration stablePeriod, bool check) {
    void afterStable() {
      _stableTimer = Timer(stablePeriod, () {
        confirm();
        if (check) unawaited(checkForUpdate());
      });
    }

    final binding = WidgetsFlutterBinding.ensureInitialized();
    binding.addPostFrameCallback((_) => afterStable());
  }

  void confirm() {
    final v = loaded;
    if (v == null || _confirmed || _failed) return;
    store.confirm(v.manifest.patchId);
    _confirmed = true;
    _removeErrorHooks();
  }

  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;
  FlutterExceptionHandler? _ourFlutterError;
  bool Function(Object, StackTrace)? _ourPlatformError;

  /// Before confirmation, an uncaught error after a patched feature was used counts as a failure
  /// of the patch (Phase 3C "exception in build()" case). Existing handlers are kept and called.
  void _installErrorHooks() {
    _previousFlutterError = FlutterError.onError;
    _ourFlutterError = (details) {
      _patchError('FlutterError: ${details.exceptionAsString()}');
      (_previousFlutterError ?? FlutterError.presentError)(details);
    };
    FlutterError.onError = _ourFlutterError;
    final dispatcher = PlatformDispatcher.instance;
    _previousPlatformError = dispatcher.onError;
    _ourPlatformError = (error, stack) {
      _patchError('uncaught ${error.runtimeType}');
      return _previousPlatformError?.call(error, stack) ?? false;
    };
    dispatcher.onError = _ourPlatformError;
  }

  void _removeErrorHooks() {
    if (_ourFlutterError != null && FlutterError.onError == _ourFlutterError) {
      FlutterError.onError = _previousFlutterError;
    }
    final dispatcher = PlatformDispatcher.instance;
    if (_ourPlatformError != null && dispatcher.onError == _ourPlatformError) {
      dispatcher.onError = _previousPlatformError;
    }
    _ourFlutterError = null;
    _ourPlatformError = null;
  }

  void _patchError(String what) {
    final v = loaded;
    if (v == null || _confirmed || _failed || !registry.patchedFeatureUsed) return;
    _failed = true;
    log('PATCH_ERROR before confirmation: $what');
    store.abandonSession();
    store.recordFailure(v.manifest.patchId, 'runtime error before confirmation: $what');
    registry.disable();
    log('LIVE_FALLBACK features use the store code for the rest of this session');
  }

  void dispose() {
    _stableTimer?.cancel();
    _removeErrorHooks();
  }

  // ---- update check --------------------------------------------------------------------------

  Future<UpdateResult> checkForUpdate() => _inFlight ??= _check().whenComplete(() => _inFlight = null);

  String get _arch => overrides?.arch ?? _abiName(Abi.current());

  static String _abiName(Abi abi) => switch (abi) {
    Abi.androidArm64 => 'arm64-v8a',
    Abi.androidArm => 'armeabi-v7a',
    Abi.androidX64 => 'x86_64',
    Abi.androidIA32 => 'x86',
    _ => abi.toString(),
  };

  Future<UpdateResult> _check() async {
    final api = UpdateApi(
      serverUrl: config.serverUrl,
      applicationId: config.appId,
      deviceFile: File('${store.dir.path}/device.json'),
      client: overrides?.httpClient ?? createDefaultHttpClient(),
    );
    try {
      final result = await _checkWith(api);
      log('UPDATE_CHECK $result');
      return result;
    } catch (e) {
      log('UPDATE_CHECK failed: ${e.runtimeType}: $e');
      return UpdateResult(UpdateStatus.failed, message: '$e');
    } finally {
      try {
        if (await api.sendEvents(store.pendingEvents)) store.removeEvents(store.pendingEvents.length);
      } catch (_) {
        // Telemetry is best effort; events are kept for the next check.
      }
    }
  }

  Future<UpdateResult> _checkWith(UpdateApi api) async {
    final activeId = store.activePatchId;
    final r = await api.check(
      platform: 'android',
      arch: _arch,
      releaseVersion: config.releaseVersion ?? info.appVersion,
      channel: config.channel,
      currentPatchNumber: store.serverRef(activeId)?.number ?? 0,
      failedPatchIds: store.failedServerIds,
    );
    if (r.applicationId != config.appId) {
      return const UpdateResult(UpdateStatus.rejected, message: 'application id mismatch');
    }
    final releaseId = r.releaseId;
    if (releaseId == null) return const UpdateResult(UpdateStatus.upToDate, message: 'release not registered');
    if (releaseId != config.releaseId) {
      return const UpdateResult(UpdateStatus.rejected, message: 'the server release id differs from this build');
    }

    var restart = false;
    // 1. Revocation list: root-signed, monotonic sequence. Applied before anything is offered.
    final rev = r.revocations;
    if (rev != null && r.revocationsReleaseId == config.releaseId) {
      try {
        final list = verifyRevocations(rev, host: config.hostIdentity('0' * 64), keys: _noDirectKeys, trust: trust);
        if (list.sequence > store.revocationSequence && store.applyRevocations(list)) {
          if (activeId != null && list.patchIds.contains(activeId)) restart = true;
        }
      } on PatchRejected catch (e) {
        log('REJECTED revocation list [${e.code}] ${e.reason}');
      }
    }
    // 2. Server rollback / revocation by patch number (existing ADR-0005 behaviour).
    final bad = r.badPatchNumbers;
    bool isBad(String? id) => id != null && bad.contains(store.serverRef(id)?.number);
    if (isBad(store.previousPatchId)) store.blacklist(store.previousPatchId!, 'rolled back on the server');
    if (isBad(store.pendingPatchId)) store.dropPending('rolled back on the server');
    if (isBad(activeId) && store.activePatchId == activeId) {
      store.rollback(activeId!, 'rolled back on the server');
      restart = true;
    }

    final offer = r.patch;
    if (offer == null) {
      if (r.otherFormat != null) log('UPDATE_IGNORED a "${r.otherFormat}" patch is not for this runtime');
      return restart ? const UpdateResult(UpdateStatus.rollbackRestartRequired) : const UpdateResult(UpdateStatus.upToDate);
    }
    return _install(api, offer);
  }

  Future<UpdateResult> _install(UpdateApi api, DbcPatchOffer p) async {
    UpdateResult reject(String why) {
      log('REJECTED offered patch ${p.number}: $why');
      return UpdateResult(UpdateStatus.rejected, patchNumber: p.number, message: why);
    }

    if (!isValidPatchId(p.serverId) || !isValidPatchId(p.patchId)) return reject('invalid patch id');
    if (p.arch != _arch) return reject('arch mismatch');
    if (store.pendingPatchId == p.patchId) {
      return UpdateResult(UpdateStatus.stagedRestartRequired, patchNumber: p.number);
    }
    if (store.activePatchId == p.patchId) return const UpdateResult(UpdateStatus.upToDate);
    final sec = store.security;
    if (sec.blacklist.contains(p.patchId)) return reject('patch previously failed on this device');
    if (sec.revokedPatchIds.contains(p.patchId)) return reject('patch is revoked');
    if (p.sequence <= sec.highestSequence) return reject('replay: sequence ${p.sequence} <= ${sec.highestSequence}');

    final tmp = File('${store.tmpDir.path}/${p.serverId}.download');
    final Uint8List bytes;
    try {
      try {
        await api.download(p, tmp);
      } on DownloadSizeError catch (e) {
        return reject(e.message);
      } on InsecureUrlException catch (e) {
        return reject(e.message);
      }
      bytes = tmp.readAsBytesSync();
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
    if (sha256.convert(bytes).toString() != p.sha256) return reject('container SHA-256 mismatch');

    // Cryptographic and compatibility checks (Phase 3C pipeline), as a NEW patch.
    final libapp = await libappSha256();
    final VerifiedPatch v;
    try {
      v = _verify(bytes, store.security, libapp, reinstall: false);
    } on PatchRejected catch (e) {
      return reject('[${e.code}] ${e.reason}');
    }
    if (v.manifest.patchId != p.patchId || v.manifest.sequence != p.sequence) {
      return reject('the server metadata differs from the signed manifest');
    }
    store.markDownloaded(v, p.ref);

    // Load it once in the separate verifier process before it can ever reach this process.
    PatchStore.atomicWrite(store.candidateModule, v.module);
    final VerifyOutcome outcome;
    try {
      outcome = await platform.verifyInProcess(
        store.candidateModule,
        loader,
        timeout: overrides?.verifyTimeout ?? const Duration(seconds: 30),
      );
    } finally {
      if (store.candidateModule.existsSync()) store.candidateModule.deleteSync();
    }
    log('VERIFY_PROCESS status=$outcome');
    if (outcome.status == 'UNAVAILABLE') {
      // Not the module's fault (the verifier could not start): not activated, not blacklisted.
      return UpdateResult(UpdateStatus.failed, patchNumber: p.number, message: 'verifier unavailable: ${outcome.detail}');
    }
    if (!outcome.ok) {
      // Authentic (signed) but unusable: never activate; blacklist so it is not tried again.
      store.blacklist(v.manifest.patchId, 'separate-process verification ${outcome.status}');
      return reject('separate-process verification ${outcome.status}: ${outcome.detail}');
    }
    store.stagePending(bytes, v, p.ref);
    return UpdateResult(UpdateStatus.stagedRestartRequired, patchNumber: p.number);
  }
}
