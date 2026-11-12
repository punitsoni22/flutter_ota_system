// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

part 'src/model.g.dart';

// The library itself is clean; the compile error is in its (generated-style) part file.
String run() => describe(Model(2));
