// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Inheritance, super calls, virtual dispatch through a base type, mixins, interfaces.

class Shape {
  String describe() => 'shape';

  double area() => 0;
}

class Square extends Shape {
  final double side;

  Square(this.side);

  @override
  String describe() => 'square/${super.describe()}';

  @override
  double area() => side * side;
}

class Circle extends Shape {
  final double r;

  Circle(this.r);

  @override
  double area() => 3 * r * r;
}

mixin Greeter {
  String get name;

  String greet() => 'Hi $name';
}

class Person with Greeter {
  @override
  final String name;

  Person(this.name);
}

abstract class Repo {
  int count();
}

class MemRepo implements Repo {
  @override
  int count() => 1;
}
