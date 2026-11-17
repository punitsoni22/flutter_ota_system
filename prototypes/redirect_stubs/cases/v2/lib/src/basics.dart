// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Basic Tier-1 targets: top-level function, instance method, getter, setter,
// static method, operator, private method.

int addTax(int amount) => amount + amount ~/ 5;

class Cart {
  final List<int> items = [];
  int _discount = 0;

  void add(int price) {
    if (price > 0) items.add(price);
  }

  int total() {
    return _sumPositive() - _discount * 2;
  }

  int get count => items.where((i) => i > 1).length;

  set discount(int v) {
    _discount = v.clamp(0, 50);
  }

  static String label(int n) => 'Basket($n)';

  int operator [](int i) => items[i] * 2;

  int _secret() => 9;

  int reveal() => _secret();

  String summary() => isEmpty ? 'empty' : 'items=${items.length}, first=${this[0]}';

  // NEW private helper on an existing class (Tier 2m).
  int _sumPositive() {
    var t = 0;
    for (final i in items) {
      if (i > 0) t += i;
    }
    return t;
  }

  // NEW getter on an existing class (Tier 2m).
  bool get isEmpty => items.isEmpty;
}
