// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Code run in a background isolate (known risk H4: slots are per isolate).

import 'dart:isolate';

int heavy(int n) => n * n;

Future<int> inIsolate(int n) => Isolate.run(() => heavy(n));
