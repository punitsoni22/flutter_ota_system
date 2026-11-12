// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:native_crypto/native_crypto.dart';
import 'package:undeclared_native/undeclared_native.dart';

// undeclared_native is compiled into the module (not a host package) but was not declared.
String run() => '${nativeCryptoVersion()} ${processId()}';
