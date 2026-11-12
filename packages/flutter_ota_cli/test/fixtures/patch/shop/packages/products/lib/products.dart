// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Products feature.
library;

import 'package:flutter_ota_system/flutter_ota_system.dart' as ota;

export 'src/model.dart';

/* class NotTheEntryFeature {} */
// class ProductsFeature is declared below.
class ProductsFeature extends ota.OtaFeature {
  const ProductsFeature();

  @override
  Object build(Object context, [Object? arguments]) => 'products: ${"{"}';
}
