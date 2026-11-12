// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi';

typedef _Pid = Int32 Function();

/// Pure-Dart API; the FFI call is an implementation detail.
int nativePid() => DynamicLibrary.process().lookupFunction<_Pid, int Function()>('getpid')();
String nativeCryptoVersion() => 'native_crypto 1.0';
