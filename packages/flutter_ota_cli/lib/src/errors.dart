// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// A user-facing error: the CLI prints [message] (no stack trace) and exits with [exitCode].
class CliException implements Exception {
  CliException(this.message, {this.exitCode = 1});

  final String message;
  final int exitCode;

  @override
  String toString() => message;
}

/// The toolchain index could not be trusted (bad, missing or unknown-key signature, bad format).
class IndexVerificationException extends CliException {
  IndexVerificationException(super.message);
}

/// A downloaded file did not match the size or SHA-256 recorded in the signed index.
class IntegrityException extends CliException {
  IntegrityException(super.message);
}

/// A download stopped before the end. The partial file is kept so the next run can resume.
class DownloadInterruptedException extends CliException {
  DownloadInterruptedException(super.message);
}

/// Not enough free disk space for the requested operation.
class DiskSpaceException extends CliException {
  DiskSpaceException(super.message);
}

/// Another process holds the install lock for this toolchain.
class LockBusyException extends CliException {
  LockBusyException(super.message);
}

/// The toolchain pinned by `flutter_ota.lock` is missing or failed verification. The CLI never
/// falls back to another (stock or global) Flutter SDK.
class ToolchainUnavailableException extends CliException {
  ToolchainUnavailableException(super.message);
}
