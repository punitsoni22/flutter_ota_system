// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Private top-level function, private class, private static field and method, private enum.

int _bonus(int x) => x + 1;

class _Calc {
  int run(int x) => x * 2;
}

int compute(int x) => _Calc().run(_bonus(x));

class Hits {
  static int _hits = 0;

  static int hit() => ++_hits;

  static int _peek() => _hits;

  static String report() => 'hits=${_peek()}';
}

enum _Mode { a, b }

String mode() => _Mode.a.name;
