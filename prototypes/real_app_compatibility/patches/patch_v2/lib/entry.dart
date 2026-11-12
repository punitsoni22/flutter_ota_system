// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:feature_catalog/feature_catalog.dart';
import 'package:feature_profile/feature_profile.dart';

import 'assets_v2.dart';

@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => <String, Object?>{
      'contract': 2,
      'patch': 'v2',
      'catalog': CatalogFeatureImpl(),
      'profile': ProfileFeatureImpl(),
      'assets': assetOverrides,
    };
