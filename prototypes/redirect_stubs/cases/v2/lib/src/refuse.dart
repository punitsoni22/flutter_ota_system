// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Changes the tool must REFUSE (structure changes of non-widget classes, enum values,
// class headers, global initializers).

class Account {
  int balance = 0;
  int deposits = 0;

  int deposit(int x) {
    deposits++;
    return balance += x * deposits;
  }
}

enum Plan { free, pro, team }

String plans() => Plan.values.map((p) => p.name).join(',');

class Dog implements Comparable<Dog> {
  String bark() => 'WOOF';

  @override
  int compareTo(Dog other) => 0;
}

final formatter = (int x) => 'n$x';

String fmtNum(int n) => formatter(n);
