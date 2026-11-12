// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Products feature of the demo app.
///
/// The app never uses this package's classes directly. It calls [ProductsFeature] through the
/// host-owned contract type `OtaFeature` (see lib/flutter_ota_features.g.dart in the app), so a
/// patch can replace everything in this package.
library;

// Deprecated from Flutter 3.47 (replacement: package:material_ui), still the standard library.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

import 'src/presentation/product_screen.dart';

/// Entry class of the feature. Its name follows the convention `<PascalName>Feature`.
class ProductsFeature extends OtaFeature {
  ProductsFeature();

  @override
  Widget build(BuildContext context, [Object? arguments]) => const ProductScreen();
}
