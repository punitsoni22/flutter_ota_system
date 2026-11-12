// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'crash_catalog.dart';

@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => <String, Object?>{'contract': 2, 'catalog': CrashCatalog(Failure.abortOnNavigation)};
