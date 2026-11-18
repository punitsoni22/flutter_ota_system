// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Micro- and mixed benchmarks to measure the cost of the redirect checks.
// Identical in v1 and v2.

class Vec {
  double x, y;

  Vec(this.x, this.y);

  double dot(Vec o) => x * o.x + y * o.y;

  double get len2 => x * x + y * y;
}

int addOne(int x) => x + 1;

int loopAdd(int n) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    s = addOne(s);
  }
  return s;
}

double loopVec(int n) {
  final a = Vec(1, 2);
  final b = Vec(3, 4);
  var s = 0.0;
  for (var i = 0; i < n; i++) {
    s += a.dot(b) + a.len2;
    a.x += 0.000001;
  }
  return s;
}

class Order {
  final int id;
  final double price;
  final int qty;

  Order(this.id, this.price, this.qty);

  double get value => price * qty;

  bool isLarge() => value > 500;

  String describe() => 'Order#$id ${value.toStringAsFixed(2)}';
}

int mixedWork(int n) {
  final orders = [for (var i = 0; i < n; i++) Order(i, (i % 97) * 1.5, i % 13)];
  final large = orders.where((o) => o.isLarge()).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final text = large.take(200).map((o) => o.describe()).join(';');
  final byQty = <int, double>{};
  for (final o in orders) {
    byQty[o.qty] = (byQty[o.qty] ?? 0) + o.value;
  }
  return text.length + byQty.length + large.length;
}

int _median(List<int> xs) => (xs..sort())[xs.length ~/ 2];

void runBench({void Function(String) out = print}) {
  void time(String name, void Function() body) {
    final runs = <int>[];
    for (var r = 0; r < 7; r++) {
      final sw = Stopwatch()..start();
      body();
      runs.add(sw.elapsedMicroseconds);
    }
    out('$name\t${_median(runs)}');
  }

  var sink = 0.0;
  time('call_small_fn_x50M', () => sink += loopAdd(50000000));
  time('method_getter_x20M', () => sink += loopVec(20000000));
  time('mixed_app_logic_x30', () {
    for (var i = 0; i < 30; i++) {
      sink += mixedWork(20000);
    }
  });
  out('sink\t${sink > 0}');
}
