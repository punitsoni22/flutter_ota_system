// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

// `dynamic` used only as a TYPE: no dynamic invocation.
String run() {
  final Map<String, dynamic> m = (jsonDecode('{"id": 1}') as Map).cast<String, dynamic>();
  final dynamic d = m['id'];
  m['copy'] = d;
  final List<dynamic> list = [d, 'x'];
  return '${d.toString()} ${d == 1} ${d.hashCode == d.hashCode} ${list.length} $m';
}
