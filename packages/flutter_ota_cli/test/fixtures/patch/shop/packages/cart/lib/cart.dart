// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:core/core.dart' show CartApi;

import 'src/base.dart';

class CartFeature extends CartBase {
  CartFeature({this.start = 0});
  final int start;
  @override
  int count() => start;
}
