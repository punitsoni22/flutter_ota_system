// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Verification of developer-signed `dbc-v1` patches: container `OTAPRT02`, canonical manifest v2,
/// ES256 signatures, key certificates, approvals, revocation lists and toolchain provenance.
///
/// Ported unchanged in logic from the Phase 3C prototype package `patch_security` (69 tests, now
/// in `test/security/`). Internal to the SDK: not exported by `flutter_ota_system.dart`.
library;

export 'canonical.dart';
export 'certs.dart';
export 'container.dart';
export 'manifest.dart';
export 'signature.dart';
export 'verifier.dart';
