// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

class Box {
  int twice(int x) => x * 2;
}

String run() => '${(Box() as dynamic).twice(2)}';
