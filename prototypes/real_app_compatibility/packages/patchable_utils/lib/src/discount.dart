// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'format.dart'; // cycle: format.dart imports discount.dart

/// Applies a percentage discount, rounding down to whole paise.
int applyDiscount(int paise, int percent) => paise - (paise * percent) ~/ 100;

String roundingMode() => 'floor';

String discountLabel(int paise, int percent) => '${formatPrice(applyDiscount(paise, percent))} (-$percent%)';
