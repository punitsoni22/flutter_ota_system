// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:native_crypto/native_crypto.dart';

// Calls a pure-Dart function of an UNCHANGED host package that uses FFI internally.
String run() => nativeCryptoVersion();
