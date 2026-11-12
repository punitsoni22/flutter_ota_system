// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:patchable_utils/patchable_utils.dart';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'multi_dup', 'run': run};

Future<Map<String, Object?>> run() async => {'formatPrice': formatPrice(12300)};
