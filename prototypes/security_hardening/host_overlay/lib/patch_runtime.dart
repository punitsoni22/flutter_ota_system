// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 3 prototype secure runtime (replaces the Phase 2 patch_runtime.dart in the host build).
// NOT production code.
//
// A NEW patch reaches the main process's module loader only after:
//   1. verifyPatch(): container bounds, canonical manifest, app/release/libapp.so binding, trusted
//      and non-revoked key, ES256 signature, module SHA-256 and size, package metadata, runtime and
//      interface compatibility, blacklist/revocation/replay/expiry (package:patch_security);
//   2. an ISOLATED LOAD in a separate Android process (":otaverify"): the Dart VM reads every
//      declaration and every function's bytecode at load time and aborts the process on malformed
//      input, so a malformed module kills only that process.
// The stored active patch is re-verified cryptographically (step 1) at every start.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dynamic_modules/dynamic_modules.dart' as dm;
import 'package:flutter/services.dart';
import 'package:patch_security/patch_security.dart';

const appId = String.fromEnvironment('OTA_APP_ID');
const baselineId = String.fromEnvironment('OTA_BASELINE_ID');
// Build-time identity. JSON values are base64 and lists use ';' (dart-defines split on commas).
const _publicKeysB64 = String.fromEnvironment('OTA_PUBLIC_KEYS_B64');
const _interfaceSha256 = String.fromEnvironment('OTA_INTERFACE_SHA256');
const _hostPackagesCsv = String.fromEnvironment('OTA_HOST_PACKAGES');
const _runtimeB64 = String.fromEnvironment('OTA_RUNTIME_B64');
Map<String, String> _b64Json(String v) => v.isEmpty ? {} : (jsonDecode(utf8.decode(base64.decode(v))) as Map).cast<String, String>();

/// Module entry-point contract version (map of slot overrides).
const moduleContract = 2;
const maxFailures = 2;

const package = 'io.github.punitsoni22.compat_host';
final inboxDir = Directory('/storage/emulated/0/Android/data/$package/files/inbox');
final resultsDir = Directory('/storage/emulated/0/Android/data/$package/files/results');
final storeDir = Directory('/data/user/0/$package/files/ota');

void log(String message) => print('[compat] $message');

const _host = MethodChannel('ota/host');

/// Android's record of how the previous process ended (API 30+).
class ExitInfo {
  ExitInfo(this.reason, this.description, this.status);
  final int reason;
  final String description;
  final int status;
  static const names = {
    0: 'UNKNOWN', 1: 'EXIT_SELF', 2: 'SIGNALED', 3: 'LOW_MEMORY', 4: 'CRASH', 5: 'CRASH_NATIVE',
    6: 'ANR', 7: 'INITIALIZATION_FAILURE', 8: 'PERMISSION_CHANGE', 9: 'EXCESSIVE_RESOURCE_USAGE',
    10: 'USER_REQUESTED', 11: 'USER_STOPPED', 12: 'DEPENDENCY_DIED', 13: 'OTHER', 14: 'FREEZER',
    15: 'PACKAGE_STATE_CHANGE', 16: 'PACKAGE_UPDATED',
  };
  String get name => names[reason] ?? 'REASON_$reason';
  bool get notAPatchFailure => const {3, 10, 11, 15, 16}.contains(reason);
  @override
  String toString() => '$name(status=$status${description.isEmpty ? '' : ', $description'})';
}

Future<ExitInfo?> lastExitInfo() async {
  try {
    final m = await _host.invokeMapMethod<String, Object?>('lastExit');
    if (m == null) return null;
    return ExitInfo(m['reason']! as int, m['description'] as String? ?? '', m['status'] as int? ?? 0);
  } catch (e) {
    log('exit info unavailable: $e');
    return null;
  }
}

/// SHA-256 of the libapp.so inside the installed APK, computed natively (never taken from input).
Future<String> installedLibappSha256() async => (await _host.invokeMethod<String>('libappSha256'))!;

/// Loads [moduleFile] in the separate ":otaverify" process. Returns {status, detail, ms}.
/// status: OK | REJECTED (clean Dart error) | CRASHED (process died) | TIMEOUT.
Future<Map<String, Object?>> verifyInIsolatedProcess(File moduleFile, {int timeoutMs = 20000}) async {
  final r = await _host.invokeMapMethod<String, Object?>('verifyIsolated', {'path': moduleFile.path, 'timeoutMs': timeoutMs});
  return r ?? {'status': 'CRASHED', 'detail': 'no result'};
}

HostIdentity hostIdentity(String libappSha) => HostIdentity(
      appId: appId,
      releaseId: baselineId,
      baselineLibappSha256: libappSha,
      runtime: _b64Json(_runtimeB64),
      interfaceSha256: _interfaceSha256,
      hostPackages: _hostPackagesCsv.split(';').where((s) => s.isNotEmpty).toSet(),
      hostOwnedPackages: const {'app_core', 'app_models', 'shared_state', 'dynamic_modules', 'flutter', 'sky_engine'},
      entryContract: moduleContract,
    );

Es256Verifier trustedKeys() => Es256Verifier(_b64Json(_publicKeysB64));

class BootResult {
  BootResult(this.patch, this.overrides, this.loadMs);
  final VerifiedPatch patch;
  final Map<Object?, Object?> overrides;
  final double loadMs;
  String get id => patch.manifest.patchId;
  String get label => '#${patch.manifest.sequence} ${patch.manifest.patchId.substring(0, 8)}';
}

/// Persistent device security state (private storage, atomic writes).
class SecureStore {
  File get active => File('${storeDir.path}/active.otp');
  File get stateFile => File('${storeDir.path}/state.json');
  File get attempt => File('${storeDir.path}/attempt.json');
  File get staging => File('${storeDir.path}/staging.otp');
  File get candidateModule => File('${storeDir.path}/candidate.bc');
  File get previous => File('${storeDir.path}/previous.otp');

  late Map<String, Object?> _s;

  void load() {
    try {
      _s = stateFile.existsSync() ? (jsonDecode(stateFile.readAsStringSync()) as Map).cast<String, Object?>() : {};
    } catch (e) {
      // Corrupted local metadata: keep the active file only if it re-verifies; start counters anew.
      log('STATE_CORRUPT ($e): security state reset (active patch is re-verified)');
      _s = {};
    }
  }

  void save() => _atomicWrite(stateFile, utf8.encode(jsonEncode(_s)));

  static void _atomicWrite(File f, List<int> bytes) {
    final tmp = File('${f.path}.tmp');
    final raf = tmp.openSync(mode: FileMode.write);
    raf.writeFromSync(bytes);
    raf.flushSync();
    raf.closeSync();
    tmp.renameSync(f.path);
  }

  DeviceSecurityState get security => DeviceSecurityState(
        highestSequence: _s['highest_sequence'] as int? ?? 0,
        blacklist: ((_s['blacklist'] as List?) ?? const []).cast<String>().toSet(),
        revokedPatchIds: ((_s['revoked_patch_ids'] as List?) ?? const []).cast<String>().toSet(),
        revokedKeyIds: ((_s['revoked_key_ids'] as List?) ?? const []).cast<String>().toSet(),
        activePatchId: _s['active_patch_id'] as String?,
      );

  Map<String, int> get _failures => ((_s['failures'] as Map?) ?? {}).cast<String, int>();

  void _delete(File f) {
    if (f.existsSync()) f.deleteSync();
  }

  void blacklist(String id, String why) {
    _s['blacklist'] = {...security.blacklist, id}.toList();
    if (_s['active_patch_id'] == id) _dropActive();
    _delete(attempt);
    save();
    log('BLACKLISTED patch=${id.substring(0, 8)} ($why); last known-good state: ${_s['active_patch_id'] == null ? 'baseline' : 'patch ${(_s['active_patch_id']! as String).substring(0, 8)}'}');
  }

  /// Removes the active patch and restores the previous CONFIRMED patch if there is one (it is
  /// re-verified before it is loaded), otherwise the baseline.
  void _dropActive() {
    _delete(active);
    _s.remove('active_patch_id');
    final prevId = _s.remove('previous_patch_id') as String?;
    if (prevId != null && previous.existsSync() && !security.blacklist.contains(prevId)) {
      previous.renameSync(active.path);
      _s['active_patch_id'] = prevId;
      log('RESTORED_PREVIOUS patch=${prevId.substring(0, 8)} (last confirmed patch)');
    } else {
      _delete(previous);
    }
  }

  bool recordFailure(String id, String why) {
    final f = _failures;
    final n = (f[id] ?? 0) + 1;
    f[id] = n;
    _s['failures'] = f;
    save();
    log('FAILURE_COUNT patch=${id.substring(0, 8)} count=$n/$maxFailures reason="$why"');
    if (n >= maxFailures) {
      blacklist(id, 'failed $n starts');
      log('ROLLED_BACK patch=${id.substring(0, 8)}; baseline will run');
      return true;
    }
    return false;
  }

  void confirm(String id) {
    if (attempt.existsSync()) {
      _delete(attempt);
      final f = _failures..remove(id);
      _s['failures'] = f;
      save();
      log('CONFIRMED patch=${id.substring(0, 8)} start confirmed');
    }
  }

  /// Verifies and (if accepted) installs an incoming patch file. The active patch is replaced only
  /// after every check passed; on any failure it is untouched.
  Future<void> installIncoming(File incoming, HostIdentity host, Es256Verifier keys) async {
    final bytes = incoming.readAsBytesSync();
    incoming.deleteSync();
    final sw = Stopwatch()..start();
    final VerifiedPatch v;
    try {
      v = verifyPatch(bytes, host: host, keys: keys, state: security, now: DateTime.now().toUtc());
    } on PatchRejected catch (e) {
      log('REJECTED incoming patch [${e.code}] ${e.reason} (active patch kept: ${security.activePatchId?.substring(0, 8) ?? 'baseline'})');
      return;
    }
    final cryptoMs = sw.elapsedMicroseconds / 1000;
    // Isolated structural/runtime check: load the module in a separate process.
    _atomicWrite(candidateModule, v.module);
    final iso = await verifyInIsolatedProcess(candidateModule);
    _delete(candidateModule);
    log('ISOLATED_VERIFY status=${iso['status']} ms=${iso['ms']} detail="${iso['detail']}" crypto_ms=${cryptoMs.toStringAsFixed(1)}');
    if (iso['status'] != 'OK') {
      // Authentic (signed) but unusable: never activate; blacklist so it is not tried again.
      blacklist(v.manifest.patchId, 'isolated verification ${iso['status']}');
      log('REJECTED incoming patch [isolated_${(iso['status'] as String).toLowerCase()}] (active patch kept)');
      return;
    }
    // Atomic activation: staging -> active, then the state (sequence/active id).
    _atomicWrite(staging, bytes);
    final kill = File('${inboxDir.path}/KILL_DURING_ACTIVATION'); // test-only hook
    if (kill.existsSync()) {
      kill.deleteSync();
      log('TEST_HOOK killing the process during activation (staged, not yet active)');
      Process.killPid(pid, ProcessSignal.sigkill);
      sleep(const Duration(seconds: 5));
    }
    final oldId = _s['active_patch_id'] as String?;
    if (oldId != null && active.existsSync() && !attempt.existsSync() && !_failures.containsKey(oldId)) {
      active.renameSync(previous.path); // keep the last confirmed patch as the fallback
      _s['previous_patch_id'] = oldId;
    } else {
      _delete(previous);
      _s.remove('previous_patch_id');
    }
    staging.renameSync(active.path);
    _delete(attempt);
    _s['highest_sequence'] = v.manifest.sequence;
    _s['active_patch_id'] = v.manifest.patchId;
    final f = _failures..remove(v.manifest.patchId);
    _s['failures'] = f;
    save();
    log('INSTALLED patch #${v.manifest.sequence} ${v.manifest.patchId.substring(0, 8)} (${bytes.length} bytes)');
  }

  void applyRevocations(File file, HostIdentity host, Es256Verifier keys) {
    final bytes = file.readAsBytesSync();
    file.deleteSync();
    try {
      final r = verifyRevocations(bytes, host: host, keys: keys);
      if (r.sequence <= (_s['revocation_sequence'] as int? ?? 0)) {
        log('REJECTED revocation list [replay] sequence ${r.sequence}');
        return;
      }
      _s['revocation_sequence'] = r.sequence;
      _s['revoked_patch_ids'] = {...security.revokedPatchIds, ...r.patchIds}.toList();
      _s['revoked_key_ids'] = {...security.revokedKeyIds, ...r.keyIds}.toList();
      save();
      log('REVOCATIONS applied sequence=${r.sequence} patches=${r.patchIds.length} keys=${r.keyIds.length}');
    } on PatchRejected catch (e) {
      log('REJECTED revocation list [${e.code}] ${e.reason}');
    }
  }

  /// Boot sequence. Never throws: any problem means the last known-good state runs.
  Future<BootResult?> boot(ExitInfo? lastExit) async {
    try {
      final reset = File('${inboxDir.path}/RESET_STORE'); // test-only hook
      if (reset.existsSync()) {
        reset.deleteSync();
        if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
        log('TEST_HOOK private patch store wiped');
      }
      await storeDir.create(recursive: true);
      for (final leftover in [File('${active.path}.tmp'), File('${staging.path}.tmp'), staging, candidateModule]) {
        if (leftover.existsSync()) {
          leftover.deleteSync();
          log('LEFTOVER ${leftover.path.split('/').last} from an interrupted activation removed');
        }
      }
      load();
      final libapp = await installedLibappSha256();
      final host = hostIdentity(libapp);
      final keys = trustedKeys();

      final rollback = File('${inboxDir.path}/ROLLBACK');
      if (rollback.existsSync()) {
        rollback.deleteSync();
        _delete(active);
        _delete(previous);
        _delete(attempt);
        _s.remove('active_patch_id');
        _s.remove('previous_patch_id');
        save();
        log('ROLLBACK requested: active and previous patches removed, baseline will run');
      }
      final truncate = File('${inboxDir.path}/STORE_TRUNCATE'); // test-only hook
      if (truncate.existsSync()) {
        truncate.deleteSync();
        if (active.existsSync()) {
          final b = active.readAsBytesSync();
          active.writeAsBytesSync(b.sublist(0, b.length ~/ 2), flush: true);
          log('TEST_HOOK stored patch truncated');
        }
      }
      final revocations = File('${inboxDir.path}/revocations.otp');
      if (revocations.existsSync()) applyRevocations(revocations, host, keys);
      final incoming = File('${inboxDir.path}/patch.otp');
      if (incoming.existsSync()) await installIncoming(incoming, host, keys);

      if (attempt.existsSync()) {
        final id = (jsonDecode(attempt.readAsStringSync()) as Map)['patch'] as String;
        _delete(attempt);
        if (lastExit != null && lastExit.notAPatchFailure) {
          log('UNCONFIRMED_START patch=${id.substring(0, 8)} ended by $lastExit: not counted');
        } else {
          log('UNCONFIRMED_START patch=${id.substring(0, 8)} previous exit: ${lastExit ?? 'unknown'}');
          recordFailure(id, 'start not confirmed (${lastExit?.name ?? 'unknown'})');
        }
      }
      if (!active.existsSync()) {
        log('NO_PATCH running baseline (AOT) code');
        return null;
      }
      // Re-verify the stored patch at every start (tampering, torn writes, revocation, new
      // release). If it fails, the previous confirmed patch (if any) is re-verified instead.
      VerifiedPatch? v;
      for (var tries = 0; v == null && tries < 2 && active.existsSync(); tries++) {
        try {
          v = verifyPatch(active.readAsBytesSync(), host: host, keys: keys, state: security, now: DateTime.now().toUtc(), reinstall: true);
        } on PatchRejected catch (e) {
          log('STORED_PATCH_INVALID [${e.code}] ${e.reason}: removed');
          _dropActive();
          save();
        }
      }
      if (v == null) {
        log('NO_PATCH running baseline (AOT) code');
        return null;
      }
      _atomicWrite(attempt, utf8.encode(jsonEncode({'patch': v.manifest.patchId, 'started': DateTime.now().toIso8601String()})));
      final sw = Stopwatch()..start();
      final Object? result;
      try {
        result = await dm.loadModuleFromBytes(Uint8List.fromList(v.module));
      } catch (e) {
        _delete(attempt);
        log('MODULE_LOAD_FAILED: ${e.runtimeType}: $e');
        recordFailure(v.manifest.patchId, 'module load/entry failed');
        return null;
      }
      final loadMs = sw.elapsedMicroseconds / 1000;
      if (result is! Map || result['contract'] != moduleContract) {
        _delete(attempt);
        recordFailure(v.manifest.patchId, 'entry point returned an unexpected value');
        return null;
      }
      log('LOADED patch #${v.manifest.sequence} ${v.manifest.patchId.substring(0, 8)} in ${loadMs.toStringAsFixed(1)} ms');
      return BootResult(v, result, loadMs);
    } catch (e) {
      log('BOOT_ERROR ($e): running baseline (AOT) code');
      return null;
    }
  }

  /// Verify-only requests (security tests): crypto + isolated verification, never activated.
  Future<Map<String, Object?>> verifyOnly(File f) async {
    final bytes = f.readAsBytesSync();
    f.deleteSync();
    final libapp = await installedLibappSha256();
    try {
      final v = verifyPatch(bytes, host: hostIdentity(libapp), keys: trustedKeys(), state: DeviceSecurityState(), now: DateTime.now().toUtc());
      final tmp = File('${storeDir.path}/verifyonly.bc');
      _atomicWrite(tmp, v.module);
      final iso = await verifyInIsolatedProcess(tmp);
      _delete(tmp);
      return {'crypto': 'OK', ...iso};
    } on PatchRejected catch (e) {
      return {'crypto': 'REJECTED', 'code': e.code, 'detail': e.reason, 'status': 'NOT_RUN'};
    }
  }
}
