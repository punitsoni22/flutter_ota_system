// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Asset bytes carried INSIDE the bytecode module (Part 10 experiment). The host's overlay asset
// bundle serves them in place of the APK's assets.

import 'dart:convert';
import 'dart:typed_data';

final Map<String, Uint8List> assetOverrides = {
  'assets/config.json': utf8.encode('{"title": "Shop (config from patch v2)", "featured": "p1"}'),
  'assets/strings_en.json': utf8.encode('{"welcome": "Welcome (strings from patch v2)"}'),
  // A NEW asset that is not in the APK.
  'assets/new_banner.json': utf8.encode('{"banner": "added by patch v2"}'),
  // Replaces the 4x4 blue logo with an 8x2 orange one.
  'assets/logo.png': base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAgAAAACCAIAAADq9gq6AAAAEUlEQVR4nGP4UCGCFTHgkgAAX9AXwbYwnhIAAAAASUVORK5CYII='),
};
