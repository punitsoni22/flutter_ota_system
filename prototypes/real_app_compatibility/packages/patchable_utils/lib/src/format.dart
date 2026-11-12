// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'discount.dart'; // cycle: discount.dart imports format.dart
import 'platform_name_stub.dart' if (dart.library.io) 'platform_name_io.dart';

part 'format.g.dart';

const String currencySymbol = '₹';

/// Version 1 of the price label: whole rupees.
String formatPrice(int paise) => '$currencySymbol${paise ~/ 100}';

String describePricing() => 'rounding=${roundingMode()} platform=$platformName';
