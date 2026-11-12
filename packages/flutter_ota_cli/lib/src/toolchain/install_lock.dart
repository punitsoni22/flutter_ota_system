// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import '../errors.dart';

/// A cross-process lock: the lock file is created exclusively and holds the owner's pid. A lock
/// whose process no longer exists (an install that crashed or was killed) is taken over.
class InstallLock {
  InstallLock._(this.path);

  final String path;

  static InstallLock acquire(String path, {required String what}) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        f.createSync(exclusive: true);
        f.writeAsStringSync('$pid\n');
        return InstallLock._(path);
      } on FileSystemException {
        final owner = _readPid(f);
        if (owner != null && owner != pid && processAlive(owner)) {
          throw LockBusyException(
            'Another flutter_ota process (pid $owner) is already working on $what. '
            'Wait for it to finish and try again.',
          );
        }
        if (owner == null && _recent(f)) {
          // Just created by another process that has not written its pid yet.
          throw LockBusyException('Another flutter_ota process is starting to work on $what. Try again shortly.');
        }
        if (owner == pid) {
          throw LockBusyException('$what is already being installed by this process.');
        }
        // Stale lock (owner gone, or the file is empty/garbled): remove it and retry once.
        try {
          f.deleteSync();
        } on FileSystemException {
          // Raced with another process; the retry decides.
        }
      }
    }
    throw LockBusyException('Could not take the lock $path for $what.');
  }

  void release() {
    final f = File(path);
    if (_readPid(f) == pid) f.deleteSync();
  }

  static bool _recent(File f) {
    try {
      return DateTime.now().difference(f.lastModifiedSync()) < const Duration(seconds: 10);
    } on FileSystemException {
      return false;
    }
  }

  static int? _readPid(File f) {
    try {
      return int.tryParse(f.readAsStringSync().trim());
    } on FileSystemException {
      return null;
    }
  }
}

/// Linux: a process exists while `/proc/<pid>` exists.
bool processAlive(int processId) => Directory('/proc/$processId').existsSync();
