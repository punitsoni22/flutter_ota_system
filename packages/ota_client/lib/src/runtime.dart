// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// How a patch is executed (ADR-0001). The rest of the client never depends on it.
///
/// Implementations: [MockPatchRuntime] now; the Android engine fork (Track R) later.
abstract interface class PatchRuntime {
  /// Formats this runtime can run. Sent to the server on every check.
  Set<String> get supportedFormats;

  /// Must equal the release's runtime_abi on the server, e.g. "ota-runtime-v1".
  String get runtimeAbi;

  /// Called with a payload whose hash AND signature are already verified.
  /// Must leave the result in [patchDir]. Called before the patch is ever activated.
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir);

  /// Called once at app start by [OtaClient.boot] with the patch to run (null = store build).
  /// Throwing here makes the client fall back to the store build.
  Future<void> load(PatchRecord? patch, Directory? patchDir);
}

/// `mock-v1`: the payload is an inert file (e.g. JSON config) that the app reads at start.
///
/// It proves the whole pipeline (sign → rollout → download → verify → stage → boot protection)
/// without executing code. Track R swaps in the engine-fork runtime with the same interface.
class MockPatchRuntime implements PatchRuntime {
  Uint8List? _activePayload;

  /// The active patch's bytes, or null when the store build runs.
  Uint8List? get activePayload => _activePayload;

  @override
  Set<String> get supportedFormats => const {'mock-v1'};

  @override
  String get runtimeAbi => 'ota-runtime-v1';

  @override
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir) async {
    await patchDir.create(recursive: true);
    await verifiedPayload.rename('${patchDir.path}/payload');
  }

  @override
  Future<void> load(PatchRecord? patch, Directory? patchDir) async {
    _activePayload = null;
    if (patch == null || patchDir == null) return;
    final bytes = await File('${patchDir.path}/payload').readAsBytes();
    // Never trust the disk: re-check the hash before every use.
    if (sha256.convert(bytes).toString() != patch.payloadSha256) {
      throw StateError('Patch ${patch.number} payload hash mismatch on disk');
    }
    _activePayload = bytes;
  }
}

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
