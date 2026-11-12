// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Private patch store and crash state machine of the bytecode runtime. Ported from the Phase 3C
// prototype (host_overlay/lib/patch_runtime.dart, verified on a phone) with these changes:
//  - generic location <filesDir>/flutter_ota/ (no hard-coded package names);
//  - no test hooks (no inbox, RESET_STORE, KILL_DURING_ACTIVATION, STORE_TRUNCATE, verify-only);
//  - a new patch is verified in the background and activated at the NEXT start (never a live code
//    swap), through a journaled, resumable activation;
//  - security state is reset when the store release changes (patch sequences are per release);
//  - device events for the existing /v1/events/batch endpoint.
//
// States of one patch:
//   DOWNLOADED -> VERIFIED -> PROBATIONARY -> ACTIVE
//   PROBATIONARY/ACTIVE -> SUSPECTED_FAILURE      (crash attributed to a patched session)
//   SUSPECTED_FAILURE  -> ACTIVE                  (a later session ended without a crash)
//   SUSPECTED_FAILURE  -> ROLLED_BACK -> BLACKLISTED   (maxFailures attributed failures)
//   ACTIVE -> ROLLED_BACK (explicit, e.g. server rollback)
//   DOWNLOADED -> BLACKLISTED (verification in the separate process failed)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../security/security.dart';
import 'exit_info.dart';

/// Attributed failures after which a patch is rolled back and blacklisted.
const maxFailures = 2;

/// Unconfirmed starts NOT attributed to a crash (force-stop, eviction, ...) tolerated in a row. A
/// patch that never reaches confirmation is counted as failed even if no start looks like a crash.
const maxUnconfirmedStarts = 3;

/// Server-side identity of a patch (for update checks and events).
class ServerPatchRef {
  const ServerPatchRef(this.id, this.number);
  final String id;
  final int number;
}

/// Persistent device security state (private storage, atomic writes) and the crash state machine.
///
/// All file operations are synchronous and small; this class never touches the network.
class PatchStore {
  PatchStore(this.dir, {required this.pid, required void Function(String) log, DateTime Function()? now})
    // ignore: prefer_initializing_formals
    : _log = log,
      _now = now ?? DateTime.now;

  /// `<filesDir>/flutter_ota`.
  final Directory dir;

  /// Process id of this start (written into the session markers).
  final int pid;
  final void Function(String) _log;
  final DateTime Function() _now;

  File get active => File('${dir.path}/active.otp');
  File get previous => File('${dir.path}/previous.otp');
  File get pending => File('${dir.path}/pending.otp');
  File get stateFile => File('${dir.path}/state.json');
  File get attempt => File('${dir.path}/attempt.json');
  File get session => File('${dir.path}/session.json');

  /// Where the module bytes are written for the separate verifier process.
  File get candidateModule => File('${dir.path}/verify/candidate.bc');
  Directory get tmpDir => Directory('${dir.path}/tmp');

  Map<String, Object?> _s = {};

  // ---- files ---------------------------------------------------------------------------------

  /// Creates the store, removes leftovers of an interrupted run, loads the state, resets it when
  /// the store release changed, and finishes an interrupted activation.
  void open(String releaseId) {
    dir.createSync(recursive: true);
    for (final leftover in [
      File('${active.path}.tmp'),
      File('${pending.path}.tmp'),
      File('${stateFile.path}.tmp'),
      File('${attempt.path}.tmp'),
      File('${session.path}.tmp'),
      candidateModule,
      File('${candidateModule.path}.tmp'),
    ]) {
      if (leftover.existsSync()) {
        leftover.deleteSync();
        _log('LEFTOVER ${leftover.path.split('/').last} from an interrupted run removed');
      }
    }
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    _load();
    final storedRelease = _s['release_id'];
    if (storedRelease == null) {
      // First start, or a corrupted state file: keep the files; the active patch must still
      // re-verify (its manifest is bound to this release) before it is loaded.
      _s['release_id'] = releaseId;
      save();
    } else if (storedRelease != releaseId) {
      _log('NEW_RELEASE store release changed: patches of the old release removed');
      for (final f in [active, previous, pending, attempt, session]) {
        _delete(f);
      }
      for (final k in const ['active_patch_id', 'previous_patch_id', 'pending', 'activation', 'highest_sequence']) {
        _s.remove(k);
      }
      _s['release_id'] = releaseId;
      save();
    }
    if (_s['activation'] != null) {
      _log('ACTIVATION_RESUME an interrupted activation is finished now');
      _finishActivation();
    }
  }

  void _load() {
    try {
      _s = stateFile.existsSync() ? (jsonDecode(stateFile.readAsStringSync()) as Map).cast<String, Object?>() : {};
    } catch (e) {
      // Corrupted local metadata: keep the active file only if it re-verifies; start counters anew.
      _log('STATE_CORRUPT (${e.runtimeType}): security state reset (the active patch is re-verified)');
      _s = {};
    }
  }

  void save() => atomicWrite(stateFile, utf8.encode(jsonEncode(_s)));

  /// Writes [bytes] to `<file>.tmp`, flushes it to disk, then renames it over [f].
  static void atomicWrite(File f, List<int> bytes) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeFromSync(bytes);
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(f.path);
  }

  void _delete(File f) {
    if (f.existsSync()) f.deleteSync();
  }

  Map<String, Object?>? _readJson(File f) {
    try {
      return f.existsSync() ? (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  // ---- state ---------------------------------------------------------------------------------

  /// The security state handed to [verifyPatch].
  DeviceSecurityState get security => DeviceSecurityState(
    highestSequence: _s['highest_sequence'] as int? ?? 0,
    blacklist: _strings('blacklist'),
    revokedPatchIds: _strings('revoked_patch_ids'),
    revokedKeyIds: _strings('revoked_key_ids'),
    revokedCertSerials: ((_s['revoked_cert_serials'] as List?) ?? const []).cast<int>().toSet(),
    activePatchId: _s['active_patch_id'] as String?,
  );

  Set<String> _strings(String k) => ((_s[k] as List?) ?? const []).cast<String>().toSet();

  String? get activePatchId => _s['active_patch_id'] as String?;
  String? get previousPatchId => _s['previous_patch_id'] as String?;
  int get revocationSequence => _s['revocation_sequence'] as int? ?? 0;

  /// Manifest patch id of the verified patch waiting for the next start, if any.
  String? get pendingPatchId => (_s['pending'] as Map?)?['patch_id'] as String?;

  Map<String, String> get _states => ((_s['states'] as Map?) ?? {}).cast<String, String>();

  /// State of patch [id] (`UNKNOWN` if never seen).
  String stateOf(String id) => _states[id] ?? 'UNKNOWN';

  Map<String, int> get _failures => ((_s['failures'] as Map?) ?? {}).cast<String, int>();

  /// Attributed failures of patch [id].
  int failuresOf(String id) => _failures[id] ?? 0;

  static String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

  /// Records a state transition of one patch (persisted with the next [save]).
  void _to(String id, String state, String why) {
    final st = _states;
    final from = st[id] ?? '-';
    st[id] = state;
    _s['states'] = st;
    _log('STATE patch=${_short(id)} $from -> $state ($why)');
  }

  // ---- server ids and events -----------------------------------------------------------------

  /// Server id and number of the patch with manifest id [manifestId], if known.
  ServerPatchRef? serverRef(String? manifestId) {
    final m = ((_s['server'] as Map?) ?? const {})[manifestId];
    if (m is! Map || m['id'] is! String || m['number'] is! int) return null;
    return ServerPatchRef(m['id']! as String, m['number']! as int);
  }

  void _rememberServerRef(String manifestId, ServerPatchRef ref) {
    final m = ((_s['server'] as Map?) ?? {}).cast<String, Object?>();
    m[manifestId] = {'id': ref.id, 'number': ref.number};
    // Keep the map small: only patches that are still referenced by state.
    final keep = {activePatchId, previousPatchId, pendingPatchId, manifestId};
    if (m.length > 32) m.removeWhere((k, _) => !keep.contains(k));
    _s['server'] = m;
  }

  /// Server ids of patches that failed here, for `failed_patch_ids` (at most 20, newest first).
  List<String> get failedServerIds => [
    for (final id in _strings('blacklist').toList().reversed)
      if (serverRef(id) case final ref?) ref.id,
  ].take(20).toList();

  /// Queued device events: `{type, patch_id}` with the SERVER patch id.
  List<Map<String, String>> get pendingEvents =>
      ((_s['events'] as List?) ?? const []).map((e) => (e as Map).cast<String, String>()).toList();

  void removeEvents(int count) {
    final e = pendingEvents;
    _s['events'] = e.sublist(count.clamp(0, e.length));
    save();
  }

  void _event(String type, String manifestId) {
    final ref = serverRef(manifestId);
    if (ref == null) return;
    final e = pendingEvents..add({'type': type, 'patch_id': ref.id});
    _s['events'] = e.length > 100 ? e.sublist(e.length - 100) : e;
  }

  // ---- crash state machine -------------------------------------------------------------------

  void blacklist(String id, String why) {
    _s['blacklist'] = {..._strings('blacklist'), id}.toList();
    _to(id, 'BLACKLISTED', why);
    if (_s['active_patch_id'] == id) _dropActive();
    if (pendingPatchId == id) _dropPending('blacklisted');
    _delete(attempt);
    save();
    final good = _s['active_patch_id'] as String?;
    _log('BLACKLISTED patch=${_short(id)} ($why); last known-good state: ${good == null ? 'store build' : 'patch ${_short(good)}'}');
  }

  /// Removes the active patch and restores the previous CONFIRMED patch if there is one (it is
  /// re-verified before it is loaded), otherwise the store build.
  void _dropActive() {
    _delete(active);
    _s.remove('active_patch_id');
    final prevId = _s.remove('previous_patch_id') as String?;
    if (prevId != null && previous.existsSync() && !_strings('blacklist').contains(prevId)) {
      previous.renameSync(active.path);
      _s['active_patch_id'] = prevId;
      _log('RESTORED_PREVIOUS patch=${_short(prevId)} (last confirmed patch)');
    } else {
      _delete(previous);
    }
  }

  /// Counts one failure of [id]. Returns true when the patch was rolled back and blacklisted.
  bool recordFailure(String id, String why) {
    final f = _failures;
    final n = (f[id] ?? 0) + 1;
    f[id] = n;
    _s['failures'] = f;
    _event('patch_boot_failed', id);
    save();
    _log('FAILURE_COUNT patch=${_short(id)} count=$n/$maxFailures reason="$why"');
    _to(id, 'SUSPECTED_FAILURE', why);
    if (n >= maxFailures) {
      _to(id, 'ROLLED_BACK', '$n attributed failures');
      _event('patch_auto_rollback', id);
      blacklist(id, 'failed $n starts');
      _log('ROLLED_BACK patch=${_short(id)}; the last known-good code runs from the next start');
      return true;
    }
    save();
    return false;
  }

  /// Marks the start of a patched session (before the module is loaded).
  void startSession(String id) {
    atomicWrite(
      attempt,
      utf8.encode(jsonEncode({'patch': id, 'pid': pid, 'started': _now().toUtc().toIso8601String()})),
    );
    _log('SESSION_START patch=${_short(id)} state=${stateOf(id)} pid=$pid');
  }

  /// Ends the current session without a confirmation and without counting (for example the
  /// failure was already counted by the caller).
  void abandonSession() => _delete(attempt);

  /// Health confirmation of the current start. A PROBATIONARY patch becomes ACTIVE; a
  /// SUSPECTED_FAILURE patch keeps its failure count (it failed AFTER an earlier confirmation)
  /// until a session ends without a crash. Returns true if the start was confirmed now.
  bool confirm(String id) {
    if (!attempt.existsSync()) return false;
    _delete(attempt);
    if (stateOf(id) == 'SUSPECTED_FAILURE') {
      _log('CONFIRMED patch=${_short(id)} start confirmed (still suspected: ${_failures[id] ?? 0}/$maxFailures)');
    } else {
      final f = _failures..remove(id);
      _s['failures'] = f;
      final u = ((_s['unconfirmed'] as Map?) ?? {}).cast<String, int>()..remove(id);
      _s['unconfirmed'] = u;
      if (stateOf(id) != 'ACTIVE') {
        _to(id, 'ACTIVE', 'health check passed');
        _event('patch_boot_succeeded', id);
      }
      _log('CONFIRMED patch=${_short(id)} start confirmed');
    }
    atomicWrite(session, utf8.encode(jsonEncode({'patch': id, 'pid': pid, 'confirmed': true})));
    save();
    return true;
  }

  /// Attributes the end of the previous patched session (Phase 3C crash state machine). Must run
  /// before anything new is activated: the session belongs to the old patch.
  void attributePreviousSession(ExitInfo? lastExit) {
    final unconfirmed = _readJson(attempt);
    final previousSession = _readJson(session);
    _delete(attempt);
    _delete(session);
    final rec = unconfirmed ?? previousSession;
    if (rec == null) return;
    final id = rec['patch'];
    if (id is! String) return;
    final kind = lastExit?.kindFor(rec['pid'] as int?) ?? ExitKind.unknown;
    final when = unconfirmed != null ? 'before confirmation' : 'after confirmation';
    _log('SESSION_END patch=${_short(id)} $when exit=${lastExit ?? 'unknown'} kind=${kind.name}');
    if (_strings('blacklist').contains(id)) return;
    switch (kind) {
      case ExitKind.crash:
        recordFailure(id, 'crash $when (${lastExit?.name})');
      case ExitKind.unknown when unconfirmed != null:
        // No evidence either way for an unconfirmed start: count it (conservative, Phase 3).
        recordFailure(id, 'start not confirmed (exit unknown)');
      case ExitKind.unknown:
        _log('NOT_COUNTED patch=${_short(id)}: exit after confirmation unknown');
      case ExitKind.forceStop || ExitKind.osEviction || ExitKind.normal:
        _log('NOT_COUNTED patch=${_short(id)} ended by ${kind.name} $when: not counted');
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

  // ---- new patches (background) --------------------------------------------------------------

  /// Records that patch [v] passed the cryptographic checks (state DOWNLOADED).
  void markDownloaded(VerifiedPatch v, ServerPatchRef ref) {
    _rememberServerRef(v.manifest.patchId, ref);
    _to(v.manifest.patchId, 'DOWNLOADED', 'authentic: signature, hashes and compatibility verified');
    _event('patch_downloaded', v.manifest.patchId);
    save();
  }

  /// Stores [bytes] (already verified, also in the separate process) as the patch for the NEXT
  /// start. The running code and the active patch file are not touched.
  void stagePending(Uint8List bytes, VerifiedPatch v, ServerPatchRef ref) {
    final old = pendingPatchId;
    if (old != null && old != v.manifest.patchId) _log('PENDING_REPLACED patch=${_short(old)} by a newer patch');
    atomicWrite(pending, bytes);
    _rememberServerRef(v.manifest.patchId, ref);
    _s['pending'] = {
      'patch_id': v.manifest.patchId,
      'sha256': sha256.convert(bytes).toString(),
      'sequence': v.manifest.sequence,
    };
    _to(v.manifest.patchId, 'VERIFIED', 'separate-process verification OK; activates at the next start');
    _event('patch_staged', v.manifest.patchId);
    save();
    _log('STAGED patch #${v.manifest.sequence} ${_short(v.manifest.patchId)} (${bytes.length} bytes): restart required');
  }

  void _dropPending(String why) {
    final id = pendingPatchId;
    _delete(pending);
    _s.remove('pending');
    if (id != null) _log('PENDING_DROPPED patch=${_short(id)} ($why)');
  }

  /// Drops the pending patch (e.g. revoked by the server).
  void dropPending(String why) {
    _dropPending(why);
    save();
  }

  /// At start-up, after [attributePreviousSession]: makes the pending patch the active one.
  /// [verify] re-checks the bytes cryptographically against the current security state (as a NEW
  /// patch, so replays are refused) and throws [PatchRejected] if they are not acceptable.
  void activatePending(VerifiedPatch Function(Uint8List bytes, DeviceSecurityState state) verify) {
    final rec = (_s['pending'] as Map?)?.cast<String, Object?>();
    if (rec == null) {
      _delete(pending);
      return;
    }
    final id = rec['patch_id'] as String? ?? '';
    if (!pending.existsSync()) {
      _dropPending('file missing');
      save();
      return;
    }
    final bytes = pending.readAsBytesSync();
    if (sha256.convert(bytes).toString() != rec['sha256']) {
      _dropPending('file changed after verification');
      save();
      return;
    }
    final VerifiedPatch v;
    try {
      v = verify(bytes, security);
    } on PatchRejected catch (e) {
      _log('REJECTED pending patch [${e.code}] ${e.reason} (active patch kept: ${_short(activePatchId ?? 'store build')})');
      _dropPending('rejected: ${e.code}');
      save();
      return;
    }
    if (v.manifest.patchId != id) {
      _dropPending('manifest id differs from the staged record');
      save();
      return;
    }
    final oldId = _s['active_patch_id'] as String?;
    final keepPrevious =
        oldId != null && active.existsSync() && stateOf(oldId) == 'ACTIVE' && !_failures.containsKey(oldId);
    // Journal first: if the process dies during the renames, open() finishes the activation.
    _s['activation'] = {'new': id, 'old': oldId, 'keep_previous': keepPrevious, 'sequence': v.manifest.sequence};
    save();
    _finishActivation();
  }

  /// Idempotent second half of the activation (also used to resume after a kill).
  void _finishActivation() {
    final j = (_s['activation']! as Map).cast<String, Object?>();
    final newId = j['new']! as String;
    final oldId = j['old'] as String?;
    final keepPrevious = j['keep_previous'] == true;
    if (pending.existsSync()) {
      if (keepPrevious) {
        if (active.existsSync()) active.renameSync(previous.path); // keep the last confirmed patch
      } else {
        _delete(active);
        _delete(previous);
      }
      pending.renameSync(active.path);
    } else if (!active.existsSync()) {
      // Neither file exists: nothing can be activated.
      _s.remove('activation');
      _s.remove('pending');
      save();
      _log('ACTIVATION_ABORTED patch=${_short(newId)}: file missing');
      return;
    }
    if (keepPrevious) {
      _s['previous_patch_id'] = oldId;
    } else {
      _s.remove('previous_patch_id');
    }
    _delete(attempt);
    _delete(session);
    _to(newId, 'PROBATIONARY', 'activated; waiting for a confirmed start');
    final seq = j['sequence'] as int? ?? 0;
    if (seq > (_s['highest_sequence'] as int? ?? 0)) _s['highest_sequence'] = seq;
    _s['active_patch_id'] = newId;
    final f = _failures..remove(newId);
    _s['failures'] = f;
    _s.remove('pending');
    _s.remove('activation');
    save();
    _log('ACTIVATED patch #$seq ${_short(newId)}${keepPrevious ? ' (previous ${_short(oldId!)} kept as fallback)' : ''}');
  }

  /// Re-verifies the stored active patch (tampering, torn writes, revocation, new release). If it
  /// fails, the previous confirmed patch (if any) is re-verified instead. Returns null when the
  /// store build must run.
  VerifiedPatch? verifyStored(VerifiedPatch Function(Uint8List bytes, DeviceSecurityState state) verify) {
    VerifiedPatch? v;
    for (var tries = 0; v == null && tries < 2 && active.existsSync(); tries++) {
      try {
        v = verify(active.readAsBytesSync(), security);
      } on PatchRejected catch (e) {
        _log('STORED_PATCH_INVALID [${e.code}] ${e.reason}: removed');
        _dropActive();
        save();
      }
    }
    if (v != null && v.manifest.patchId != _s['active_patch_id']) {
      // State and file disagree (for example the state file was lost): trust the verified file.
      _s['active_patch_id'] = v.manifest.patchId;
      if (stateOf(v.manifest.patchId) == 'UNKNOWN') _to(v.manifest.patchId, 'PROBATIONARY', 'recovered from the store');
      save();
    }
    return v;
  }

  // ---- revocation and rollback ---------------------------------------------------------------

  /// Applies a verified revocation list. Returns false for a replay (sequence not newer).
  bool applyRevocations(RevocationList r) {
    if (r.sequence <= revocationSequence) {
      _log('REJECTED revocation list [replay] sequence ${r.sequence} <= $revocationSequence');
      return false;
    }
    _s['revocation_sequence'] = r.sequence;
    _s['revoked_patch_ids'] = {..._strings('revoked_patch_ids'), ...r.patchIds}.toList();
    _s['revoked_key_ids'] = {..._strings('revoked_key_ids'), ...r.keyIds}.toList();
    _s['revoked_cert_serials'] = {
      ...((_s['revoked_cert_serials'] as List?) ?? const []).cast<int>(),
      ...r.certSerials,
    }.toList();
    final p = pendingPatchId;
    if (p != null && r.patchIds.contains(p)) _dropPending('revoked');
    save();
    _log(
      'REVOCATIONS applied sequence=${r.sequence} patches=${r.patchIds.length} keys=${r.keyIds.length} '
      'cert_serials=${r.certSerials.length} (checked again at every start)',
    );
    return true;
  }

  /// Explicit rollback of patch [id] (for example the server rolled it back or revoked it). It is
  /// blacklisted; the previous confirmed patch or the store build runs from the next start.
  void rollback(String id, String why) {
    _to(id, 'ROLLED_BACK', why);
    blacklist(id, why);
  }
}
