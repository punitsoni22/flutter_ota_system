// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:feature_catalog/feature_catalog.dart';
import 'package:patchable_utils/patchable_utils.dart';

@pragma('dyn-module:entry-point')
Object? otaPatchEntry() {
  print('[compat] NOTE ' + 'module formatPrice(49900)=${formatPrice(49900)}');
  return <String, Object?>{
      'contract': 2,
      'patch': 'v3_stale',
      // The HOST's CatalogFeatureImpl: it still uses the host's product_service/patchable_utils.
      'catalog': CatalogFeatureImpl(),
  };
}
