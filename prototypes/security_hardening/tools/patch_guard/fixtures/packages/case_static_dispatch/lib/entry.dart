// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

abstract class Shape {
  double area();
}

class Square implements Shape {
  Square(this.s);
  final double s;
  @override
  double area() => s * s;
}

// Statically typed calls with runtime (virtual) dispatch, closures and Function.apply on a
// statically known function.
String run() {
  final List<Shape> shapes = [Square(2), Square(3)];
  final int Function(int) inc = (x) => x + 1;
  int add(int a, int b) => a + b;
  return '${shapes.map((s) => s.area()).join(',')} ${inc(1)} ${Function.apply(add, [1, 2])}';
}
