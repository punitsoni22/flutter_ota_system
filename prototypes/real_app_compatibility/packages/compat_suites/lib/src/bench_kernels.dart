// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Benchmark kernels. Each returns a checksum so the interpreted and AOT runs can be compared.

import 'dart:async';
import 'dart:convert';

import 'package:app_models/app_models.dart';
import 'package:flutter/widgets.dart';

@pragma('vm:never-inline')
int _add(int a, int b) => a + b;

int simpleCalls() {
  var s = 0;
  for (var i = 0; i < 200000; i++) {
    s = _add(s, i) & 0xFFFFFF;
  }
  return s;
}

/// Cart pricing with discounts and tax over model objects (typical business logic).
int businessLogic() {
  const products = [
    Product(id: 'a', title: 'A', pricePaise: 49900, category: Category.books),
    Product(id: 'b', title: 'B', pricePaise: 129900, category: Category.electronics),
    Product(id: 'c', title: 'C', pricePaise: 9900, category: Category.grocery),
  ];
  var total = 0;
  for (var cart = 0; cart < 3000; cart++) {
    var sum = 0;
    for (var i = 0; i < 6; i++) {
      final p = products[(cart + i) % products.length];
      final qty = 1 + (cart + i) % 3;
      var line = p.pricePaise * qty;
      if (p.category == Category.electronics && qty > 1) line -= line ~/ 10;
      sum += line;
    }
    final tax = sum * 18 ~/ 100;
    total = (total + sum + tax) % 1000000007;
  }
  return total;
}

int collections() {
  final list = List<int>.generate(20000, (i) => (i * 7919) % 10007);
  final sorted = [...list]..sort();
  final evens = list.where((x) => x.isEven).map((x) => x ~/ 2).toList();
  final byMod = <int, int>{};
  for (final x in list) {
    byMod.update(x % 97, (v) => v + 1, ifAbsent: () => 1);
  }
  return sorted[sorted.length ~/ 2] + evens.length + byMod.length + sorted.toSet().length;
}

int jsonRoundTrip() {
  final data = [
    for (var i = 0; i < 300; i++) {'id': 'p$i', 'price': i * 100, 'tags': ['x', 'y'], 'ok': i.isEven},
  ];
  var check = 0;
  for (var r = 0; r < 5; r++) {
    final text = jsonEncode(data);
    final back = jsonDecode(text) as List<Object?>;
    for (final e in back) {
      check += ((e! as Map<String, Object?>)['price']! as int) & 0xFF;
    }
  }
  return check;
}

int stringBuilding() {
  final b = StringBuffer();
  for (var i = 0; i < 20000; i++) {
    b
      ..write('item')
      ..write(i)
      ..write(i.isEven ? ';' : ',');
  }
  return b.toString().length;
}

int widgetConstruction() {
  var n = 0;
  for (var r = 0; r < 20; r++) {
    final tree = Column(children: [
      for (var i = 0; i < 200; i++)
        Padding(padding: const EdgeInsets.all(4), child: Row(children: [Text('row $i'), const SizedBox(width: 8)])),
    ]);
    n += tree.children.length;
  }
  return n;
}

Future<int> asyncOps() async {
  var s = 0;
  for (var i = 0; i < 5000; i++) {
    s += await Future<int>.value(i);
  }
  return s;
}

/// name -> kernel.
Map<String, FutureOr<int> Function()> benchKernels() => {
      'simple function calls (200k)': simpleCalls,
      'business logic (3k carts)': businessLogic,
      'collection processing (20k)': collections,
      'JSON encode+decode (300 items x5)': jsonRoundTrip,
      'string building (20k)': stringBuilding,
      'widget construction (20 x 200 rows)': widgetConstruction,
      'async/await (5k awaits)': asyncOps,
    };
