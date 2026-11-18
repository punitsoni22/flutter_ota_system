// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Extension members (receiver is `this`) and enum members.

extension IntX on int {
  int doubled() => this * 3;

  bool get isBig => this > 10;
}

enum Level {
  low,
  high;

  String get tag => 'L:$name';
}
