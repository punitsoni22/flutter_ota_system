// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import '../errors.dart';

/// Returns the free bytes available to this user on the file system holding [path], or null if
/// it cannot be determined.
typedef DiskSpaceProbe = Future<int?> Function(String path);

/// Uses POSIX `df -Pk` (Linux hosts only, see decision D3).
Future<int?> dfFreeBytes(String path) async {
  var p = Directory(path);
  while (!p.existsSync() && p.parent.path != p.path) {
    p = p.parent;
  }
  try {
    final r = await Process.run('df', ['-Pk', p.path]);
    if (r.exitCode != 0) return null;
    final lines = (r.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final cols = lines.last.split(RegExp(r'\s+'));
    final kb = int.tryParse(cols.length > 3 ? cols[3] : '');
    return kb == null ? null : kb * 1024;
  } on ProcessException {
    return null;
  }
}

/// Safety margin kept free after any download or extraction.
const diskSafetyMarginBytes = 512 * 1024 * 1024;

/// Throws [DiskSpaceException] when fewer than [needed] + margin bytes are free at [path].
Future<void> requireDiskSpace(DiskSpaceProbe probe, String path, int needed, String what) async {
  final free = await probe(path);
  if (free == null) return; // Unknown: the write itself will fail cleanly if the disk fills up.
  if (free < needed + diskSafetyMarginBytes) {
    throw DiskSpaceException(
      'Not enough disk space for $what: need about ${formatBytes(needed + diskSafetyMarginBytes)} '
      'free in $path, only ${formatBytes(free)} available. Free some space (for example '
      '`flutter_ota toolchain clean`) and try again.',
    );
  }
}

String formatBytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$b B' : '${v.toStringAsFixed(1)} ${units[i]}';
}
