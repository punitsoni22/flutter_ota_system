// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Basic Tier-1 targets: top-level function, instance method, getter, setter,
// static method, operator, private method.

int addTax(int amount) => amount + amount ~/ 10;

class Cart {
  final List<int> items = [];
  int _discount = 0;

  void add(int price) {
    items.add(price);
  }

  int total() {
    var t = 0;
    for (final i in items) {
      t += i;
    }
    return t - _discount;
  }

  int get count => items.length;

  set discount(int v) {
    _discount = v;
  }

  static String label(int n) => 'Cart($n)';

  int operator [](int i) => items[i];

  int _secret() => 7;

  int reveal() => _secret();

  String summary() => 'items=${items.length}';
}
