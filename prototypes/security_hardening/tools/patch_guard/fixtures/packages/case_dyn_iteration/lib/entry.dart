// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

String run() {
  final dynamic items = [1, 2, 3];
  var sum = 0;
  for (final x in items) {
    sum += x as int;
  }
  return '$sum';
}
