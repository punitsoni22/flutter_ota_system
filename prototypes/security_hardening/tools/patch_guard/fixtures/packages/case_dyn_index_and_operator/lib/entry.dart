// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

String run() {
  final dynamic json = jsonDecode('{"id": 1}');
  return '${json['id']} ${json['id'] + 1}';
}
