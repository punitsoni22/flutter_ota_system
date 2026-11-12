// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:clean_dep/clean_dep.dart';
import 'package:native_crypto/native_crypto.dart';

// clean_dep is declared (passed in --module-packages); native_crypto is a host package.
String run() => '${greeting('module')} ${nativeCryptoVersion()}';
