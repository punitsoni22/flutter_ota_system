// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:native_crypto/native_crypto.dart';

String priceLabel(int paise) => 'Product price: ₹${paise ~/ 100} (${nativeCryptoVersion()})';
