// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Crash state machine and private store (ported from the Phase 3C prototype): exit attribution,
// thresholds, previous-patch restore, journaled activation, re-verification at every start.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_system/src/bytecode/exit_info.dart';
import 'package:flutter_ota_system/src/bytecode/patch_store.dart';
import 'package:flutter_ota_system/src/security/security.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

typedef Verify = VerifiedPatch Function(Uint8List bytes, DeviceSecurityState state);

Verify verifier({required bool reinstall}) {
  final config = testConfig();
  return (b, st) => verifyPatch(
    b,
    host: config.hostIdentity(libappSha),
    keys: Es256Verifier(const {}),
    state: st,
    now: DateTime.utc(2026, 11, 12, 12),
    reinstall: reinstall,
    trust: config.certificateTrust(),
  );
}

ExitInfo crash(int pid) => ExitInfo(4, '', 0, pid);
ExitInfo nativeCrash(int pid) => ExitInfo(5, '', 0, pid);
ExitInfo segv(int pid) => ExitInfo(2, '', 11, pid);
ExitInfo forceStop(int pid) => ExitInfo(10, '', 0, pid);
ExitInfo sigkill(int pid) => ExitInfo(2, '', 9, pid);
ExitInfo lowMemory(int pid) => ExitInfo(3, '', 0, pid);
ExitInfo normal(int pid) => ExitInfo(1, '', 0, pid);

void main() {
  late Directory tmp;
  late Directory dir;
  final logs = <String>[];
  var pid = 1000;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flutter_ota_sm_');
    dir = Directory('${tmp.path}/flutter_ota');
    logs.clear();
    pid = 1000;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// One app start: returns the store and the patch that runs (null = store build).
  (PatchStore, VerifiedPatch?) start({ExitInfo? exit}) {
    final s = PatchStore(dir, pid: ++pid, log: logs.add)..open(releaseId);
    s.attributePreviousSession(exit);
    s.activatePending(verifier(reinstall: false));
    final v = s.verifyStored(verifier(reinstall: true));
    if (v != null) s.startSession(v.manifest.patchId);
    return (s, v);
  }

  /// Background download + verification of patch [n] during the session of [s].
  void stage(PatchStore s, int n) {
    final bytes = dbcContainer(n);
    final v = verifier(reinstall: false)(bytes, s.security);
    s.markDownloaded(v, ServerPatchRef('9${n.toString().padLeft(7, '0')}-1111-4111-8111-111111111111', n));
    s.stagePending(bytes, v, ServerPatchRef('9${n.toString().padLeft(7, '0')}-1111-4111-8111-111111111111', n));
  }

  test('install path: DOWNLOADED -> VERIFIED -> PROBATIONARY -> ACTIVE; activates only at the next start', () {
    var (s, v) = start();
    expect(v, isNull);
    stage(s, 1);
    expect(s.stateOf(patchUuid(1)), 'VERIFIED');
    expect(s.active.existsSync(), isFalse, reason: 'never swapped live');
    (s, v) = start(exit: normal(pid));
    expect(v!.manifest.patchId, patchUuid(1));
    expect(s.stateOf(patchUuid(1)), 'PROBATIONARY');
    expect(s.security.highestSequence, 1);
    expect(s.confirm(patchUuid(1)), isTrue);
    expect(s.stateOf(patchUuid(1)), 'ACTIVE');
    expect(s.pendingEvents.map((e) => e['type']), ['patch_downloaded', 'patch_staged', 'patch_boot_succeeded']);
    expect(s.pendingEvents.first['patch_id'], startsWith('90000001'));
    expect(logs.where((l) => l.startsWith('STATE ')), hasLength(4));
  });

  test('crash before confirmation: counted 1/2, then 2/2 -> rolled back, blacklisted, store build runs', () {
    var (s, _) = start();
    stage(s, 1);
    (s, _) = start(exit: normal(pid));
    (s, _) = start(exit: crash(pid));
    expect(s.failuresOf(patchUuid(1)), 1);
    expect(s.stateOf(patchUuid(1)), 'SUSPECTED_FAILURE');
    final VerifiedPatch? v;
    (s, v) = start(exit: nativeCrash(pid));
    expect(v, isNull);
    expect(s.stateOf(patchUuid(1)), 'BLACKLISTED');
    expect(s.security.blacklist, contains(patchUuid(1)));
    expect(logs, contains(predicate<String>((l) => l.startsWith('ROLLED_BACK'))));
    expect(s.pendingEvents.map((e) => e['type']), containsAll(['patch_boot_failed', 'patch_auto_rollback']));
    expect(s.failedServerIds, ['90000001-1111-4111-8111-111111111111']);
  });

  test('crash signal (SIGSEGV) counts; previous confirmed patch is restored after 2 failures', () {
    var (s, v) = start();
    stage(s, 1);
    (s, v) = start(exit: normal(pid));
    s.confirm(patchUuid(1));
    stage(s, 2);
    (s, v) = start(exit: normal(pid));
    expect(v!.manifest.patchId, patchUuid(2));
    expect(s.previousPatchId, patchUuid(1));
    (s, v) = start(exit: segv(pid));
    (s, v) = start(exit: crash(pid));
    expect(v!.manifest.patchId, patchUuid(1), reason: 'last confirmed patch runs again');
    expect(s.stateOf(patchUuid(2)), 'BLACKLISTED');
    expect(logs, contains(predicate<String>((l) => l.startsWith('RESTORED_PREVIOUS'))));
  });

  test('force-stop and OS eviction are not counted; 3 unconfirmed starts in a row are', () {
    var (s, _) = start();
    stage(s, 1);
    (s, _) = start(exit: normal(pid));
    (s, _) = start(exit: forceStop(pid));
    expect(s.failuresOf(patchUuid(1)), 0);
    (s, _) = start(exit: sigkill(pid));
    expect(s.failuresOf(patchUuid(1)), 0);
    (s, _) = start(exit: lowMemory(pid));
    expect(s.failuresOf(patchUuid(1)), 1, reason: 'third unconfirmed start in a row');
    expect(logs.where((l) => l.startsWith('NOT_COUNTED')), hasLength(3));
  });

  test('unknown exit: counted before confirmation, not after', () {
    var (s, _) = start();
    stage(s, 1);
    (s, _) = start(exit: normal(pid));
    (s, _) = start(); // no exit record at all
    expect(s.failuresOf(patchUuid(1)), 1);
    s.confirm(patchUuid(1));
    (s, _) = start(exit: ExitInfo(13, 'other', 0, pid));
    expect(s.failuresOf(patchUuid(1)), 1);
  });

  test('an exit record of another process is not attributed (pid mismatch -> unknown)', () {
    var (s, _) = start();
    stage(s, 1);
    (s, _) = start(exit: normal(pid));
    s.confirm(patchUuid(1));
    (s, _) = start(exit: crash(pid + 50));
    expect(s.failuresOf(patchUuid(1)), 0);
    expect(s.stateOf(patchUuid(1)), 'ACTIVE');
  });

  test('crash after confirmation -> SUSPECTED_FAILURE; a clean session -> ACTIVE again', () {
    var (s, _) = start();
    stage(s, 1);
    (s, _) = start(exit: normal(pid));
    s.confirm(patchUuid(1));
    (s, _) = start(exit: crash(pid));
    expect(s.stateOf(patchUuid(1)), 'SUSPECTED_FAILURE');
    s.confirm(patchUuid(1));
    expect(s.failuresOf(patchUuid(1)), 1, reason: 'confirmation keeps the count while suspected');
    (s, _) = start(exit: normal(pid));
    expect(s.stateOf(patchUuid(1)), 'ACTIVE');
    expect(s.failuresOf(patchUuid(1)), 0);
  });

  test('stored patch is re-verified at every start: a tampered file is removed, previous restored', () {
    var (s, v) = start();
    stage(s, 1);
    (s, v) = start(exit: normal(pid));
    s.confirm(patchUuid(1));
    stage(s, 2);
    (s, v) = start(exit: normal(pid));
    final b = s.active.readAsBytesSync();
    s.active.writeAsBytesSync(b.sublist(0, b.length ~/ 2), flush: true); // torn write
    (s, v) = start(exit: normal(pid));
    expect(v!.manifest.patchId, patchUuid(1));
    expect(logs, contains(predicate<String>((l) => l.startsWith('STORED_PATCH_INVALID ['))));
  });

  test('a pending file changed after verification is never activated', () {
    var (s, v) = start();
    stage(s, 1);
    final b = s.pending.readAsBytesSync()..[40] ^= 1;
    s.pending.writeAsBytesSync(b, flush: true);
    (s, v) = start(exit: normal(pid));
    expect(v, isNull);
    expect(s.pendingPatchId, isNull);
  });

  test('an activation killed half-way is finished at the next start (journal)', () {
    var (s, v) = start();
    stage(s, 1);
    (s, v) = start(exit: normal(pid));
    s.confirm(patchUuid(1));
    stage(s, 2);
    // Simulate a kill after "active -> previous" and before "pending -> active".
    final state = (jsonDecode(s.stateFile.readAsStringSync()) as Map).cast<String, Object?>();
    state['activation'] = {'new': patchUuid(2), 'old': patchUuid(1), 'keep_previous': true, 'sequence': 2};
    s.stateFile.writeAsStringSync(jsonEncode(state));
    s.active.renameSync(s.previous.path);
    (s, v) = start(exit: normal(pid));
    expect(v!.manifest.patchId, patchUuid(2));
    expect(s.previousPatchId, patchUuid(1));
    expect(s.previous.existsSync(), isTrue);
    expect(logs, contains(predicate<String>((l) => l.startsWith('ACTIVATION_RESUME'))));
  });

  test('leftover temporary files are removed at start', () {
    var (s, _) = start();
    File('${s.active.path}.tmp').writeAsStringSync('x');
    s.candidateModule.createSync(recursive: true);
    (s, _) = start();
    expect(File('${s.active.path}.tmp').existsSync(), isFalse);
    expect(s.candidateModule.existsSync(), isFalse);
  });

  test('a corrupted state file resets counters; the active patch still re-verifies', () {
    var (s, v) = start();
    stage(s, 1);
    (s, v) = start(exit: normal(pid));
    s.stateFile.writeAsStringSync('{not json');
    (s, v) = start(exit: normal(pid));
    expect(v!.manifest.patchId, patchUuid(1));
    expect(logs, contains(predicate<String>((l) => l.startsWith('STATE_CORRUPT'))));
  });

  test('a replayed older patch is refused when it would be activated', () {
    var (s, v) = start();
    stage(s, 2);
    (s, v) = start(exit: normal(pid));
    s.confirm(patchUuid(2));
    // An old (sequence 1) container staged by hand must not pass the fresh verification.
    final old = dbcContainer(1);
    s.pending.writeAsBytesSync(old);
    final state = (jsonDecode(s.stateFile.readAsStringSync()) as Map).cast<String, Object?>();
    state['pending'] = {'patch_id': patchUuid(1), 'sha256': sha(old), 'sequence': 1};
    s.stateFile.writeAsStringSync(jsonEncode(state));
    (s, v) = start(exit: normal(pid));
    expect(v!.manifest.patchId, patchUuid(2));
    expect(logs, contains(predicate<String>((l) => l.startsWith('REJECTED pending patch [replay]'))));
  });

  test('revocation lists: newer sequence applied, replay refused, revoked active patch dropped at start', () {
    var (s, v) = start();
    stage(s, 1);
    (s, v) = start(exit: normal(pid));
    final host = testConfig().hostIdentity(libappSha);
    final trust = testConfig().certificateTrust();
    final list = verifyRevocations(revocationList(3, patchIds: [patchUuid(1)]), host: host, keys: Es256Verifier(const {}), trust: trust);
    expect(s.applyRevocations(list), isTrue);
    final again = verifyRevocations(revocationList(3), host: host, keys: Es256Verifier(const {}), trust: trust);
    expect(s.applyRevocations(again), isFalse);
    (s, v) = start(exit: normal(pid));
    expect(v, isNull);
    expect(logs, contains(predicate<String>((l) => l.startsWith('STORED_PATCH_INVALID [revoked]'))));
  });

  test('a new store release removes the old patches and resets the sequence', () {
    var (s, v) = start();
    stage(s, 5);
    (s, v) = start(exit: normal(pid));
    expect(s.security.highestSequence, 5);
    s = PatchStore(dir, pid: ++pid, log: logs.add)..open('6a2a62a6-34c8-426a-9f57-4d99e02c3761');
    expect(s.security.highestSequence, 0);
    expect(s.active.existsSync(), isFalse);
    expect(logs, contains(predicate<String>((l) => l.startsWith('NEW_RELEASE'))));
  });

  test('explicit rollback (server) blacklists the active patch and restores the previous one', () {
    var (s, v) = start();
    stage(s, 1);
    (s, v) = start(exit: normal(pid));
    s.confirm(patchUuid(1));
    stage(s, 2);
    (s, v) = start(exit: normal(pid));
    s.rollback(patchUuid(2), 'rolled back on the server');
    (s, v) = start(exit: normal(pid));
    expect(v!.manifest.patchId, patchUuid(1));
    expect(s.stateOf(patchUuid(2)), 'BLACKLISTED');
  });

  group('ExitInfo.kind (Phase 3C table)', () {
    final table = <ExitInfo, ExitKind>{
      ExitInfo(4, '', 0): ExitKind.crash,
      ExitInfo(5, '', 0): ExitKind.crash,
      ExitInfo(6, '', 0): ExitKind.crash,
      ExitInfo(7, '', 0): ExitKind.crash,
      ExitInfo(9, '', 0): ExitKind.crash,
      ExitInfo(2, '', 6): ExitKind.crash,
      ExitInfo(2, '', 11): ExitKind.crash,
      ExitInfo(2, '', 9): ExitKind.osEviction,
      ExitInfo(3, '', 0): ExitKind.osEviction,
      ExitInfo(14, '', 0): ExitKind.osEviction,
      ExitInfo(10, '', 0): ExitKind.forceStop,
      ExitInfo(11, '', 0): ExitKind.forceStop,
      ExitInfo(1, '', 0): ExitKind.normal,
      ExitInfo(1, '', 1): ExitKind.crash,
      ExitInfo(16, '', 0): ExitKind.normal,
      ExitInfo(0, '', 0): ExitKind.unknown,
      ExitInfo(13, '', 0): ExitKind.unknown,
      ExitInfo(99, '', 0): ExitKind.unknown,
    };
    for (final MapEntry(:key, :value) in table.entries) {
      test('${key.name}/${key.status} -> ${value.name}', () => expect(key.kind, value));
    }
    test('malformed native maps are ignored', () {
      expect(ExitInfo.fromMap(null), isNull);
      expect(ExitInfo.fromMap({'reason': 'x'}), isNull);
      expect(ExitInfo.fromMap({'reason': 4, 'pid': 7, 'timestamp': 12})!.pid, 7);
    });
  });
}

String sha(Uint8List b) => sha256.convert(b).toString();
