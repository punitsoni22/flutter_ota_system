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
//
// Phase 3C additions: toolchain provenance (the manifest's toolchain id must equal the one this
// build pins), root-certified signing keys (CertificateTrust; certificate serials can be revoked),
// verification in an Android isolated process (read-only FD; logged fallback), the in-VM bytecode
// verifier (patched engine), and an explicit crash state machine per patch:
//   DOWNLOADED -> VERIFIED -> PROBATIONARY -> ACTIVE
//   PROBATIONARY/ACTIVE -> SUSPECTED_FAILURE (crash attributed to a patched session)
//   SUSPECTED_FAILURE -> ACTIVE (a later session ended without a crash)
//   SUSPECTED_FAILURE -> ROLLED_BACK -> BLACKLISTED (maxFailures attributed crashes)
//   ACTIVE -> ROLLED_BACK (explicit rollback)          DOWNLOADED -> BLACKLISTED (isolated check failed)
// How the previous process ended comes from Android's ApplicationExitInfo, matched by pid to the
// session marker: crashes count; force-stop, OS eviction and normal exits do not.

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
const _toolchainId = String.fromEnvironment('OTA_TOOLCHAIN_ID');
const _rootKeysB64 = String.fromEnvironment('OTA_ROOT_KEYS_B64');
const environment = String.fromEnvironment('OTA_ENVIRONMENT', defaultValue: 'development');
Map<String, String> _b64Json(String v) => v.isEmpty ? {} : (jsonDecode(utf8.decode(base64.decode(v))) as Map).cast<String, String>();

/// Module entry-point contract version (map of slot overrides).
const moduleContract = 2;
const maxFailures = 2;

/// Unconfirmed starts NOT attributed to a crash (force-stop, eviction...) tolerated in a row. A
/// patch that never reaches confirmation is rolled back even if no start looks like a crash.
const maxUnconfirmedStarts = 3;

const package = 'io.github.punitsoni22.compat_host';
final inboxDir = Directory('/storage/emulated/0/Android/data/$package/files/inbox');
final resultsDir = Directory('/storage/emulated/0/Android/data/$package/files/results');
final storeDir = Directory('/data/user/0/$package/files/ota');

void log(String message) => print('[compat] $message');

const _host = MethodChannel('ota/host');

/// Android's record of how the previous process ended (API 30+).
enum ExitKind { crash, forceStop, osEviction, normal, unknown }

class ExitInfo {
  ExitInfo(this.reason, this.description, this.status, [this.pid, this.timestamp]);
  final int reason;
  final String description;
  final int status;
  final int? pid;
  final int? timestamp;
  static const names = {
    0: 'UNKNOWN', 1: 'EXIT_SELF', 2: 'SIGNALED', 3: 'LOW_MEMORY', 4: 'CRASH', 5: 'CRASH_NATIVE',
    6: 'ANR', 7: 'INITIALIZATION_FAILURE', 8: 'PERMISSION_CHANGE', 9: 'EXCESSIVE_RESOURCE_USAGE',
    10: 'USER_REQUESTED', 11: 'USER_STOPPED', 12: 'DEPENDENCY_DIED', 13: 'OTHER', 14: 'FREEZER',
    15: 'PACKAGE_STATE_CHANGE', 16: 'PACKAGE_UPDATED',
  };
  String get name => names[reason] ?? 'REASON_$reason';

  /// How the process ended, for crash attribution (Phase 3C). Status is the signal for SIGNALED.
  ExitKind get kind => switch (reason) {
        4 || 5 || 6 || 7 => ExitKind.crash, // CRASH, CRASH_NATIVE, ANR, INITIALIZATION_FAILURE
        9 => ExitKind.crash, // EXCESSIVE_RESOURCE_USAGE: a symptom a bad patch can cause
        2 when const {4, 6, 7, 8, 11}.contains(status) => ExitKind.crash, // SIGILL/ABRT/BUS/FPE/SEGV
        2 when status == 9 => ExitKind.osEviction, // SIGKILL from the system (not a crash signal)
        10 || 11 => ExitKind.forceStop, // USER_REQUESTED (force-stop), USER_STOPPED
        3 || 14 => ExitKind.osEviction, // LOW_MEMORY, FREEZER
        1 when status != 0 => ExitKind.crash, // EXIT_SELF with an error status
        1 || 8 || 12 || 15 || 16 => ExitKind.normal, // EXIT_SELF(0), PERMISSION_CHANGE, DEPENDENCY_DIED, PACKAGE_*
        _ => ExitKind.unknown, // UNKNOWN, OTHER, or an unlisted reason
      };

  /// [kind] if this record belongs to the process [sessionPid], otherwise unknown.
  ExitKind kindFor(int? sessionPid) => sessionPid == null || pid == null || pid == sessionPid ? kind : ExitKind.unknown;

  @override
  String toString() => '$name(status=$status, pid=$pid${description.isEmpty ? '' : ', $description'})';
}

Future<ExitInfo?> lastExitInfo() async {
  try {
    final m = await _host.invokeMapMethod<String, Object?>('lastExit');
    if (m == null) return null;
    return ExitInfo(m['reason']! as int, m['description'] as String? ?? '', m['status'] as int? ?? 0, m['pid'] as int?,
        (m['timestamp'] as num?)?.toInt());
  } catch (e) {
    log('exit info unavailable: $e');
    return null;
  }
}

/// SHA-256 of the libapp.so inside the installed APK, computed natively (never taken from input).
Future<String> installedLibappSha256() async => (await _host.invokeMethod<String>('libappSha256'))!;

/// Loads [moduleFile] in a separate process. Returns {status, detail, ms, process, probes}.
/// status: OK | REJECTED (clean Dart error, e.g. bytecode verification) | CRASHED (process died) |
/// TIMEOUT | UNAVAILABLE (isolated process could not start Flutter; never treated as OK).
/// Phase 3C: the Android isolated process first; the same-UID ":otaverify" process only as a
/// logged fallback when the isolated one is UNAVAILABLE.
Future<Map<String, Object?>> verifyInIsolatedProcess(File moduleFile, {int timeoutMs = 20000}) async {
  Future<Map<String, Object?>> run(bool isolated) async =>
      await _host.invokeMapMethod<String, Object?>(
          'verifyIsolated', {'path': moduleFile.path, 'timeoutMs': timeoutMs, 'isolated': isolated}) ??
      {'status': 'CRASHED', 'detail': 'no result'};
  final r = await run(true);
  log('ISOLATION process=${r['process']} probes="${r['probes']}"');
  if (r['status'] != 'UNAVAILABLE') return r;
  log('ISOLATION_FALLBACK isolated process unavailable (${r['detail']}); using the same-UID :otaverify process');
  return run(false);
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
      toolchainId: _toolchainId,
    );

Es256Verifier trustedKeys() => Es256Verifier(_b64Json(_publicKeysB64));

/// Root keys of this application (Phase 3C). Directly trusted keys stay accepted in this
/// prototype build (requireCertificates: false) so Phase 3 artifacts keep working.
CertificateTrust certificateTrust() =>
    CertificateTrust(roots: Es256Verifier(_b64Json(_rootKeysB64)), environment: environment, requireCertificates: false);

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
  File get session => File('${storeDir.path}/session.json');

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
        revokedCertSerials: ((_s['revoked_cert_serials'] as List?) ?? const []).cast<int>().toSet(),
        activePatchId: _s['active_patch_id'] as String?,
      );

  Map<String, String> get _states => ((_s['states'] as Map?) ?? {}).cast<String, String>();
  String stateOf(String id) => _states[id] ?? 'UNKNOWN';

  /// Records a state transition of one patch (persisted with the next save()).
  void _to(String id, String state, String why) {
    final st = _states;
    final from = st[id] ?? '-';
    st[id] = state;
    _s['states'] = st;
    log('STATE patch=${id.substring(0, 8)} $from -> $state ($why)');
  }

  Map<String, int> get _failures => ((_s['failures'] as Map?) ?? {}).cast<String, int>();

  void _delete(File f) {
    if (f.existsSync()) f.deleteSync();
  }

  void blacklist(String id, String why) {
    _s['blacklist'] = {...security.blacklist, id}.toList();
    _to(id, 'BLACKLISTED', why);
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
    _to(id, 'SUSPECTED_FAILURE', why);
    if (n >= maxFailures) {
      _to(id, 'ROLLED_BACK', '$n attributed failures');
      blacklist(id, 'failed $n starts');
      log('ROLLED_BACK patch=${id.substring(0, 8)}; baseline will run');
      return true;
    }
    return false;
  }

  /// Health confirmation of the current start. A PROBATIONARY patch becomes ACTIVE; a
  /// SUSPECTED_FAILURE patch keeps its failure count (it failed AFTER an earlier confirmation) until
  /// a session ends without a crash.
  void confirm(String id) {
    if (attempt.existsSync()) {
      _delete(attempt);
      if (stateOf(id) == 'SUSPECTED_FAILURE') {
        log('CONFIRMED patch=${id.substring(0, 8)} start confirmed (still suspected: ${_failures[id] ?? 0}/$maxFailures)');
      } else {
        final f = _failures..remove(id);
        _s['failures'] = f;
        (_s['unconfirmed'] as Map?)?.remove(id);
        if (stateOf(id) != 'ACTIVE') _to(id, 'ACTIVE', 'health check passed');
        log('CONFIRMED patch=${id.substring(0, 8)} start confirmed');
      }
      _atomicWrite(session, utf8.encode(jsonEncode({'patch': id, 'pid': pid, 'confirmed': true})));
      save();
    }
  }

  /// Attributes the end of the previous patched session (Phase 3C crash state machine).
  void _attributePreviousSession(ExitInfo? lastExit) {
    Map<String, Object?>? read(File f) {
      try {
        return f.existsSync() ? (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>() : null;
      } catch (_) {
        return null;
      }
    }

    final unconfirmed = read(attempt);
    final previous = read(session);
    _delete(attempt);
    _delete(session);
    final rec = unconfirmed ?? previous;
    if (rec == null) return;
    final id = rec['patch']! as String;
    final kind = lastExit?.kindFor(rec['pid'] as int?) ?? ExitKind.unknown;
    final when = unconfirmed != null ? 'before confirmation' : 'after confirmation';
    log('SESSION_END patch=${id.substring(0, 8)} $when exit=${lastExit ?? 'unknown'} kind=${kind.name}');
    if (security.blacklist.contains(id)) return;
    switch (kind) {
      case ExitKind.crash:
        recordFailure(id, 'crash $when (${lastExit?.name})');
      case ExitKind.unknown when unconfirmed != null:
        // No evidence either way for an unconfirmed start: count it (conservative, Phase 3).
        recordFailure(id, 'start not confirmed (exit unknown)');
      case ExitKind.unknown:
        log('NOT_COUNTED patch=${id.substring(0, 8)}: exit after confirmation unknown');
      case ExitKind.forceStop || ExitKind.osEviction || ExitKind.normal:
        log('NOT_COUNTED patch=${id.substring(0, 8)} ended by ${kind.name} $when: not counted');
        if (unconfirmed != null) {
          final u = ((_s['unconfirmed'] as Map?) ?? {}).cast<String, int>();
          final n = (u[id] ?? 0) + 1;
          u[id] = n;
          _s['unconfirmed'] = u;
          save();
          if (n >= maxUnconfirmedStarts) recordFailure(id, '$n starts in a row never confirmed');
        }
        if (unconfirmed == null && stateOf(id) == 'SUSPECTED_FAILURE') {
          final f = _failures..remove(id);
          _s['failures'] = f;
          _to(id, 'ACTIVE', 'a session ended without a crash');
          save();
        }
    }
  }

  /// Verifies and (if accepted) installs an incoming patch file. The active patch is replaced only
  /// after every check passed; on any failure it is untouched.
  Future<void> installIncoming(File incoming, HostIdentity host, Es256Verifier keys, CertificateTrust trust) async {
    final bytes = incoming.readAsBytesSync();
    incoming.deleteSync();
    final sw = Stopwatch()..start();
    final VerifiedPatch v;
    try {
      v = verifyPatch(bytes, host: host, keys: keys, state: security, now: DateTime.now().toUtc(), trust: trust);
    } on PatchRejected catch (e) {
      log('REJECTED incoming patch [${e.code}] ${e.reason} (active patch kept: ${security.activePatchId?.substring(0, 8) ?? 'baseline'})');
      return;
    }
    final cryptoMs = sw.elapsedMicroseconds / 1000;
    _to(v.manifest.patchId, 'DOWNLOADED', 'authentic: signature, hashes and compatibility verified');
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
    if (oldId != null && active.existsSync() && stateOf(oldId) == 'ACTIVE' && !_failures.containsKey(oldId)) {
      active.renameSync(previous.path); // keep the last confirmed patch as the fallback
      _s['previous_patch_id'] = oldId;
    } else {
      _delete(previous);
      _s.remove('previous_patch_id');
    }
    staging.renameSync(active.path);
    _delete(attempt);
    _delete(session);
    _to(v.manifest.patchId, 'VERIFIED', 'isolated verification OK');
    _to(v.manifest.patchId, 'PROBATIONARY', 'activated; waiting for a confirmed start');
    _s['highest_sequence'] = v.manifest.sequence;
    _s['active_patch_id'] = v.manifest.patchId;
    final f = _failures..remove(v.manifest.patchId);
    _s['failures'] = f;
    save();
    log('INSTALLED patch #${v.manifest.sequence} ${v.manifest.patchId.substring(0, 8)} (${bytes.length} bytes)');
  }

  void applyRevocations(File file, HostIdentity host, Es256Verifier keys, CertificateTrust trust) {
    final bytes = file.readAsBytesSync();
    file.deleteSync();
    try {
      final r = verifyRevocations(bytes, host: host, keys: keys, trust: trust);
      if (r.sequence <= (_s['revocation_sequence'] as int? ?? 0)) {
        log('REJECTED revocation list [replay] sequence ${r.sequence}');
        return;
      }
      _s['revocation_sequence'] = r.sequence;
      _s['revoked_patch_ids'] = {...security.revokedPatchIds, ...r.patchIds}.toList();
      _s['revoked_key_ids'] = {...security.revokedKeyIds, ...r.keyIds}.toList();
      _s['revoked_cert_serials'] = {...security.revokedCertSerials, ...r.certSerials}.toList();
      save();
      log('REVOCATIONS applied sequence=${r.sequence} patches=${r.patchIds.length} keys=${r.keyIds.length} cert_serials=${r.certSerials.length}');
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
      final trust = certificateTrust();

      final rollback = File('${inboxDir.path}/ROLLBACK');
      if (rollback.existsSync()) {
        rollback.deleteSync();
        final rolled = _s['active_patch_id'] as String?;
        if (rolled != null) _to(rolled, 'ROLLED_BACK', 'explicit rollback');
        _delete(session);
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
      // Attribute the previous session BEFORE installing anything new (it belongs to the old patch).
      _attributePreviousSession(lastExit);
      if (revocations.existsSync()) applyRevocations(revocations, host, keys, trust);
      final incoming = File('${inboxDir.path}/patch.otp');
      if (incoming.existsSync()) await installIncoming(incoming, host, keys, trust);
      if (!active.existsSync()) {
        log('NO_PATCH running baseline (AOT) code');
        return null;
      }
      // Re-verify the stored patch at every start (tampering, torn writes, revocation, new
      // release). If it fails, the previous confirmed patch (if any) is re-verified instead.
      VerifiedPatch? v;
      for (var tries = 0; v == null && tries < 2 && active.existsSync(); tries++) {
        try {
          v = verifyPatch(active.readAsBytesSync(),
              host: host, keys: keys, state: security, now: DateTime.now().toUtc(), reinstall: true, trust: trust);
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
      _atomicWrite(attempt, utf8.encode(jsonEncode({'patch': v.manifest.patchId, 'pid': pid, 'started': DateTime.now().toIso8601String()})));
      log('SESSION_START patch=${v.manifest.patchId.substring(0, 8)} state=${stateOf(v.manifest.patchId)} pid=$pid');
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
      final v = verifyPatch(bytes,
          host: hostIdentity(libapp), keys: trustedKeys(), state: DeviceSecurityState(), now: DateTime.now().toUtc(), trust: certificateTrust());
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
