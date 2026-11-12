// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// This comment mentions import 'dart:ffi'; and DynamicLibrary.open('libc.so').
/* Pointer<Uint8> and NativeFunction<Void Function()> in a block comment. */
const note = "import 'dart:ffi'; DynamicLibrary.open('x'); @Native";

String run() => 'no ffi here: $note';
