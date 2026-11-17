// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Unchanged in v2: calls a function whose default value changes (re-pointed caller).

import 'sigs.dart';

String tagTwice() => '${tagged('b')}${tagged('c')}';
