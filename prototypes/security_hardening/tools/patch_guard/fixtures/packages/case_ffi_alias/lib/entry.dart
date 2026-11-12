// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi' as native_alias;

String run() => '${native_alias.sizeOf<native_alias.Int64>()}';
