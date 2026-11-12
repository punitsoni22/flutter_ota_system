// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Shared, host-owned code of the demo app: configuration and theme.
///
/// This package is part of the store build. A patch can use it, but can never change it.
library;

// Deprecated from Flutter 3.47 (replacement: package:material_ui), still the standard library.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

/// App-wide settings.
abstract final class DemoConfig {
  static const appTitle = 'Flutter OTA System demo';

  /// Base URL of the demo's own product API (not the OTA server).
  ///
  /// The default works on a USB phone after `adb reverse tcp:8090 tcp:8090`, with
  /// `demo_api/serve.sh` running on the computer. Plain `http://` is allowed only for
  /// 127.0.0.1 and localhost (android/app/src/main/res/xml/network_security_config.xml).
  static const productApiBaseUrl =
      String.fromEnvironment('DEMO_API_URL', defaultValue: 'http://127.0.0.1:8090');
}

/// The app's theme.
ThemeData demoTheme() => ThemeData(colorSchemeSeed: const Color(0xFF3F51B5));
