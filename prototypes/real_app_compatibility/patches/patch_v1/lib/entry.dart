// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Written against the ORIGINAL package names; pkg_rename rewrites the import of the changed
// package (feature_catalog -> feature_catalog_patch1). app_core stays the host's.
import 'package:feature_catalog/feature_catalog.dart';

@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => <String, Object?>{
      'contract': 2,
      'patch': 'v1',
      'catalog': CatalogFeatureImpl(),
    };
