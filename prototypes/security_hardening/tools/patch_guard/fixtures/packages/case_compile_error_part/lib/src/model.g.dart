// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

part of '../entry.dart';

class Model {
  Model(this.count);
  final int count;
}

// Deliberate compile error inside a part file (e.g. a stale generated file).
String describe(Model m) => m.count;
