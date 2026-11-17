// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Changes the tool must REFUSE (structure changes of non-widget classes, enum values,
// class headers, global initializers).

class Account {
  int balance = 0;

  int deposit(int x) => balance += x;
}

enum Plan { free, pro }

String plans() => Plan.values.map((p) => p.name).join(',');

class Dog {
  String bark() => 'woof';
}

final formatter = (int x) => 'x$x';

String fmtNum(int n) => formatter(n);
