// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

String run() {
  final dynamic f = (int x) => x + 1;
  final Function g = (int x) => x + 2;
  return '${f(1)} ${g(1)}';
}
