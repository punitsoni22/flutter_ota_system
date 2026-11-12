// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// The products feature as compiled into the store build.

import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

class ProductsFeature extends OtaFeature {
  ProductsFeature();

  String get version => 'store';

  @override
  Widget build(BuildContext context, [Object? arguments]) => Text('products store');
}
