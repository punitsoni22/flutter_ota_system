// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Flutter client for **Flutter OTA System**, an experimental, self-hosted over-the-air patch
/// system for Flutter apps.
///
/// The client talks to your own Flutter OTA System server. It checks for patches, downloads
/// them, verifies their size, SHA-256 and ES256 signature, stages them, activates them on the
/// next app start, and falls back automatically when a new patch fails to start.
///
/// Start with [OtaConfig] and [OtaClient]; choose a [PatchRuntime]: [MockPatchRuntime] for inert
/// data, or the experimental [AotPatchRuntime] for Android code patches.
///
/// ```dart
/// import 'package:flutter_ota_system/flutter_ota_system.dart';
/// ```
library;

export 'src/aot_runtime.dart' show AotPatchRuntime;
export 'src/models.dart' show PatchRecord, UpdateResult, UpdateStatus;
export 'src/ota_client.dart' show OtaClient, OtaConfig;
export 'src/runtime.dart' show MockPatchRuntime, PatchRuntime;
