// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

class User {
  String name = 'a';
}

String run() {
  final dynamic u = User();
  u.name = 'b';
  return u.name as String;
}
