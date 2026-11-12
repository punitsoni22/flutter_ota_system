// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'crash_catalog.dart';

// Aborts the process while the module initialises.
@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => abortProcess('in entry point');
