// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app_core/app_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Host wrapper around the shared_preferences plugin (Dart wrapper + native Android code).
class PrefsStore implements KeyValueStore {
  @override
  Future<void> setString(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);

  @override
  Future<String?> getString(String key) async => (await SharedPreferences.getInstance()).getString(key);
}
