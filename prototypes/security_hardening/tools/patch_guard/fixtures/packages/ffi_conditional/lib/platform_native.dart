// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi';

String describePlatform() => 'pointer size ${sizeOf<IntPtr>()}';
