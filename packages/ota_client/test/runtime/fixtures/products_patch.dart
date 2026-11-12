// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// The products feature as a patch carries it: a renamed copy, so a DIFFERENT type with the same name.

import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

class ProductsFeature extends OtaFeature {
  ProductsFeature();

  String get version => 'patch';

  @override
  Widget build(BuildContext context, [Object? arguments]) => Text('products patch');
}
