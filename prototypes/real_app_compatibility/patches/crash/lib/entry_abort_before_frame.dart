// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'crash_catalog.dart';

// Variant: the process dies while the module initialises, before the first frame.
@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => abortProcess('before first frame');
