// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Patch ids come from the server and are NOT covered by the patch signature (protocol v1), yet
/// the client uses them as directory and file names. Only the canonical lowercase UUID the server
/// generates (`str(uuid.uuid4())`) is accepted, so an id can never name a path such as `../..`
/// (SEC-01). Signing the id is a protocol v2 requirement (docs/security.md).
///
/// Must be identical to `PATCH_ID` in `OtaPaths.java`; a test compares the two.
const patchIdPatternSource = r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

final RegExp _patchIdPattern = RegExp(patchIdPatternSource);

bool isValidPatchId(String id) => _patchIdPattern.hasMatch(id);
