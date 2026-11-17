// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Closures, named/optional parameters, constants, patterns and records, strings,
// exceptions, late fields, recursion.

List<int> scaled(List<int> xs, int k) => xs.map((x) => x * k).toList();

String fmt(String s, {bool upper = false, int pad = 0}) =>
    (upper ? s.toUpperCase() : s).padLeft(pad);

String opt(String a, [String b = 'x']) => '$a-$b';

class Limits {
  static const int maxItems = 3;
}

bool isFull(int n) => n >= Limits.maxItems;

String classify(Object o) => switch (o) {
      int i when i > 10 => 'big',
      int _ => 'int',
      String s => 'str:$s',
      _ => 'other',
    };

(int, String) pair(int x) => (x, '$x');

String title() => 'Welcome';

int parseOr(String s) {
  try {
    return int.parse(s);
  } on FormatException {
    return -1;
  }
}

class Config {
  late final int v = _init();

  int _init() => 42;

  int read() => v;
}

int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

const String kGreeting = 'hello';

String greeting() => kGreeting;

bool isTooSmall(int n) => n < 1;
