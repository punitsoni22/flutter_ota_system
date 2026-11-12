// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Internal: the contract between OtaClient and a runtime whose code is chosen natively.

import 'dart:io';

import 'models.dart';
import 'runtime.dart';

/// A runtime whose code is chosen by native code before Dart starts (Android code patches).
///
/// [OtaClient.boot] asks it what actually loaded, instead of choosing a patch itself, and tells it
/// what to load on the next start whenever that changes.
abstract interface class NativeBootRuntime implements PatchRuntime {
  Future<NativeBootReport> readBootReport();

  /// Next start: try [next] (the newest patch), fall back to [good] (last confirmed) or the store code.
  Future<void> setNextBoot({PatchRecord? next, Directory? nextDir, PatchRecord? good, Directory? goodDir});
}

class NativeBootReport {
  const NativeBootReport({required this.enabled, this.loadedPatchId, this.failedPatchIds = const []});

  /// False in debug builds (JIT, nothing to swap) and on platforms without the native part.
  final bool enabled;

  /// The patch running now, or null for the store code.
  final String? loadedPatchId;

  /// Patches the native side refused at this start: unconfirmed last start, or failed verification.
  final List<String> failedPatchIds;
}
