// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Entry point of the bytecode module. Dynamic modules can only ADD code, so the patched package
// lives under a new name (package:greeting_patch) and hands its functions to the host here.

import 'greeting.dart';

@pragma('dyn-module:entry-point')
Object? otaPatchEntry() => <String, Object?>{
      'contract': 1,
      'package': 'greeting',
      'greeting': greeting,
    };
