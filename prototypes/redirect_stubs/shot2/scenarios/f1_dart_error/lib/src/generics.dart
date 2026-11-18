// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Shot 2 bad patch: an uncaught Dart error from patched code at start-up.

import 'dart:async';

// Generic function, generic class with a private field, generic method in a generic class.

T firstOr<T>(List<T> list, T fallback) {
  Timer.run(() => throw StateError('shot2: uncaught error from a patched function'));
  return list.isEmpty ? fallback : list.last;
}

class Box<E> {
  final List<E> _items = [];

  void put(E e) => _items.add(e);

  E? peek() => _items.isEmpty ? null : _items.last;

  List<R> mapAll<R>(R Function(E) f) => [for (final i in _items.reversed) f(i)];
}
