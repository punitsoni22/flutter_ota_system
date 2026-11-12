// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi';

// A third-party-style dependency that is neither a host package nor declared in module.yaml.
typedef _Pid = Int32 Function();

int processId() => DynamicLibrary.process().lookupFunction<_Pid, int Function()>('getpid')();
