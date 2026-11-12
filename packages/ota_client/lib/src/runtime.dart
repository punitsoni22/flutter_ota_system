// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// How a patch is applied and run. The rest of the client does not depend on it (ADR-0001).
///
/// Use one of the two built-in runtimes:
/// - [MockPatchRuntime] (`mock-v1`): inert data such as a JSON config; no code runs.
/// - [AotPatchRuntime] (`aot-bidiff-android-v1`): Android code patches (experimental).
///
/// Implementing your own runtime is possible but only useful together with a server-side
/// format of the same name; the server offers only patches whose format is in
/// [supportedFormats] and whose release runtime ABI equals [runtimeAbi].
abstract interface class PatchRuntime {
  /// Formats this runtime can run, e.g. `{'mock-v1'}`. Sent to the server on every check.
  Set<String> get supportedFormats;

  /// Must equal the release's `runtime_abi` on the server, e.g. `ota-runtime-v1`.
  String get runtimeAbi;

  /// Prepares a downloaded patch. [verifiedPayload]'s size, SHA-256 and signature are already
  /// verified. Must leave the result in [patchDir] (which it may create). Called before the
  /// patch is ever activated; throwing makes the client refuse the patch.
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir);

  /// Called once by [OtaClient.boot] with the patch to run (`null` = the store build) and its
  /// directory. Throwing makes the client fall back to the store build and never use that
  /// patch again.
  Future<void> load(PatchRecord? patch, Directory? patchDir);
}

/// Runs `mock-v1` patches: the payload is an **inert file** (e.g. a JSON config) that the app
/// reads at start. No code is downloaded or executed.
///
/// It exercises the whole pipeline (signing, rollout, download, verification, staging, boot
/// protection, rollback) and is useful for remote configuration. Call [OtaClient.boot] before
/// `runApp` and read [activePayload] while building the first screen:
///
/// ```dart
/// final runtime = MockPatchRuntime();
/// // ... OtaClient(OtaConfig(..., runtime: runtime)); await client.boot();
/// final config = runtime.activePayload == null
///     ? const <String, dynamic>{}
///     : jsonDecode(utf8.decode(runtime.activePayload!)) as Map<String, dynamic>;
/// ```
class MockPatchRuntime implements PatchRuntime {
  /// Creates the `mock-v1` runtime. Keep a reference to read [activePayload] after boot.
  MockPatchRuntime();

  Uint8List? _activePayload;

  /// The active patch's bytes, re-verified against its SHA-256 at boot, or `null` when the
  /// store build runs.
  Uint8List? get activePayload => _activePayload;

  /// Always `{'mock-v1'}`.
  @override
  Set<String> get supportedFormats => const {'mock-v1'};

  /// Always `ota-runtime-v1`.
  @override
  String get runtimeAbi => 'ota-runtime-v1';

  /// Moves the verified payload into [patchDir].
  @override
  Future<void> stage(PatchRecord patch, File verifiedPayload, Directory patchDir) async {
    await patchDir.create(recursive: true);
    await verifiedPayload.rename('${patchDir.path}/payload');
  }

  /// Reads the payload of [patch] into [activePayload] after re-checking its SHA-256. Throws a
  /// [StateError] if the file on disk no longer matches.
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
