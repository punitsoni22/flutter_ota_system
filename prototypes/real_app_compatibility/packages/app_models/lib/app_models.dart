// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Shared domain models. Host-owned and stable: patches import these, never copy them, so class
/// identity is preserved across the host/module boundary.
library;

export 'src/user.dart';
export 'src/product.dart';
