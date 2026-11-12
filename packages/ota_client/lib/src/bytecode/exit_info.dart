// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// How the previous app process ended, from Android's ApplicationExitInfo (API 30+). Used by the
// crash state machine to decide whether a patched session crashed (Phase 3C, verified on a phone).

/// How a process ended, for crash attribution.
enum ExitKind {
  /// Crash, native crash, ANR, initialisation failure, excessive resource use, a crash signal,
  /// or a self-exit with an error status. Counted against the patch.
  crash,

  /// Force-stop by the user. Not counted.
  forceStop,

  /// Low memory, freezer, or SIGKILL from the system. Not counted.
  osEviction,

  /// Normal exit or a package update. Not counted.
  normal,

  /// No record, a record of another process, or an unlisted reason.
  unknown,
}

/// One `ApplicationExitInfo` record of the app's main process.
class ExitInfo {
  const ExitInfo(this.reason, this.description, this.status, [this.pid, this.timestamp]);

  /// Builds a record from the map the Android plugin sends, or null if it is malformed.
  static ExitInfo? fromMap(Map<Object?, Object?>? m) {
    if (m == null) return null;
    final reason = m['reason'];
    if (reason is! int) return null;
    final status = m['status'];
    final pid = m['pid'];
    final ts = m['timestamp'];
    return ExitInfo(
      reason,
      m['description'] is String ? m['description']! as String : '',
      status is int ? status : 0,
      pid is int ? pid : null,
      ts is num ? ts.toInt() : null,
    );
  }

  /// `ApplicationExitInfo.REASON_*`.
  final int reason;
  final String description;

  /// Exit status, or the signal number for `REASON_SIGNALED`.
  final int status;
  final int? pid;
  final int? timestamp;

  static const names = {
    0: 'UNKNOWN',
    1: 'EXIT_SELF',
    2: 'SIGNALED',
    3: 'LOW_MEMORY',
    4: 'CRASH',
    5: 'CRASH_NATIVE',
    6: 'ANR',
    7: 'INITIALIZATION_FAILURE',
    8: 'PERMISSION_CHANGE',
    9: 'EXCESSIVE_RESOURCE_USAGE',
    10: 'USER_REQUESTED',
    11: 'USER_STOPPED',
    12: 'DEPENDENCY_DIED',
    13: 'OTHER',
    14: 'FREEZER',
    15: 'PACKAGE_STATE_CHANGE',
    16: 'PACKAGE_UPDATED',
  };

  String get name => names[reason] ?? 'REASON_$reason';

  /// How the process ended (Phase 3C table). Status is the signal number for SIGNALED.
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

  /// [kind] if this record belongs to the process [sessionPid], otherwise [ExitKind.unknown].
  ExitKind kindFor(int? sessionPid) =>
      sessionPid == null || pid == null || pid == sessionPid ? kind : ExitKind.unknown;

  @override
  String toString() => '$name(status=$status, pid=$pid${description.isEmpty ? '' : ', $description'})';
}
