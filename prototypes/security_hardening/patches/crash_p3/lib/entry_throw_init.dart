// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Throws while the module initialises (entry point).
@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => throw StateError('crash-test: entry point throws during initialisation');
