// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:clean_dep/clean_dep.dart';

// clean_dep is clean but undeclared: it would be compiled in unpinned and without a policy check.
String run() => greeting('module');
