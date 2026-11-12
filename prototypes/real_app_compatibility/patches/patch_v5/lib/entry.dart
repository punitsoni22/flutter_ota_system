// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:feature_catalog/feature_catalog.dart';

@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => <String, Object?>{'contract': 2, 'patch': 'v5', 'catalog': CatalogFeatureImpl()};
