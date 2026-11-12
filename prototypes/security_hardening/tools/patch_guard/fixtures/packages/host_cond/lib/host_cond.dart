// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// A HOST package whose browser-only conditional import reaches a non-host package with a
// dynamic call (like package:http -> package:web). On Android that code is never compiled.
import 'src/stub.dart' if (dart.library.js_interop) 'package:undeclared_dyn/undeclared_dyn.dart' as impl;

String hostLabel() => impl.twiceLabel();
