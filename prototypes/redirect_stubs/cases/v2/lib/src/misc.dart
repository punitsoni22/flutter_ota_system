// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Closures, named/optional parameters, constants, patterns and records, strings,
// exceptions, late fields, recursion.

List<int> scaled(List<int> xs, int k) =>
    xs.map((x) => x * k + 1).where((x) => x.isOdd).toList();

String fmt(String s, {bool upper = false, int pad = 0}) =>
    '[${(upper ? s.toUpperCase() : s).padLeft(pad)}]';

String opt(String a, [String b = 'x']) => '$b-$a';

class Limits {
  static const int maxItems = 5;

  // NEW static constant on an existing class (Tier 2m).
  static const int minItems = 2;
}

bool isFull(int n) => n >= Limits.maxItems;

String classify(Object o) => switch (o) {
      (int a, int b) => 'pair:${a + b}',
      int i when i > 10 => 'big',
      int _ => 'int',
      String s => 'str:$s',
      _ => 'other',
    };

(int, String) pair(int x) => (x * 2, 'v$x');

String title() => 'Welcome back';

int parseOr(String s) {
  try {
    return int.parse(s.trim());
  } on FormatException {
    return 0;
  }
}

class Config {
  late final int v = _init();

  int _init() => 7;

  int read() => v;
}

int fib(int n) => n < 2 ? 1 : fib(n - 1) + fib(n - 2);

const String kGreeting = 'hi';

String greeting() => kGreeting;

bool isTooSmall(int n) => n < Limits.minItems;
