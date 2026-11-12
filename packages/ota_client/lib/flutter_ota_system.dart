// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Flutter client for **Flutter OTA System**, an experimental, self-hosted over-the-air patch
/// system for Flutter apps.
///
/// The client talks to your own Flutter OTA System server. It checks for patches, downloads
/// them, verifies their size, SHA-256 and ES256 signature, stages them, activates them on the
/// next app start, and falls back automatically when a new patch fails to start.
///
/// Two ways to use it:
///
/// - **Bytecode runtime (Phase 4, experimental):** [FlutterOta.initialize] in `main()` and
///   [FlutterOta.feature] with [OtaFeature] for patchable features. Needs the Flutter OTA System
///   toolchain and the flutter_ota CLI. See `docs/flutter-integration-v2.md`.
/// - **Classic client:** [OtaConfig] and [OtaClient]; choose a [PatchRuntime]: [MockPatchRuntime]
///   for inert data, or the experimental [AotPatchRuntime] for Android code patches.
///
/// ```dart
/// import 'package:flutter_ota_system/flutter_ota_system.dart';
/// ```
library;

export 'src/aot_runtime.dart' show AotPatchRuntime;
export 'src/flutter_ota.dart'
    show FlutterOta, FlutterOtaModuleLoader, FlutterOtaPatchInfo, FlutterOtaStartupTimings, FlutterOtaStatus;
export 'src/models.dart' show PatchRecord, UpdateResult, UpdateStatus;
export 'src/ota_client.dart' show OtaClient, OtaConfig;
export 'src/ota_feature.dart' show OtaFeature;
export 'src/runtime.dart' show MockPatchRuntime, PatchRuntime;
