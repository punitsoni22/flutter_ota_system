// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

class _Box {
  int twice(int x) => x * 2;
}

// Dynamic call inside a dependency that is neither a host package nor declared in module.yaml.
String twiceLabel() => '${(_Box() as dynamic).twice(2)}';
