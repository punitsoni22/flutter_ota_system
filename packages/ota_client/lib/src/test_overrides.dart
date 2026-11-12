// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Internal: test-only settings. Not exported; apps cannot reach them.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Settings that tests replace: storage location and the reported platform and CPU ABI.
class OtaTestOverrides {
  const OtaTestOverrides({this.storageDir, this.platform, this.arch});

  /// Instead of `<application support directory>/ota`.
  final Directory? storageDir;

  /// Instead of the current platform (`android`).
  final String? platform;

  /// Instead of the current CPU ABI (e.g. `arm64-v8a`).
  final String? arch;
}

OtaTestOverrides _overrides = const OtaTestOverrides();

/// Read once by each new `OtaClient`. Empty in apps.
OtaTestOverrides get otaTestOverrides => _overrides;

/// Tests set this before creating a client; null restores the defaults.
@visibleForTesting
set debugOtaTestOverrides(OtaTestOverrides? value) => _overrides = value ?? const OtaTestOverrides();
