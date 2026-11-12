// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:crypto/crypto.dart';
import 'package:feature_catalog/feature_catalog.dart';

@pragma('dyn-module:entry-point')
Object? otaPatchEntry() {
  print('[compat] NOTE ' + 'module sha256("abc")=${sha256.convert('abc'.codeUnits)}');
  return <String, Object?>{
      'contract': 2,
      'patch': 'v4',
      'catalog': CatalogFeatureImpl(),
  };
}
