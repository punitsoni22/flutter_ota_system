// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

class Ghost {
  @override
  dynamic noSuchMethod(Invocation invocation) => 'ghost';
}

String run() => '${Ghost().hashCode}';
