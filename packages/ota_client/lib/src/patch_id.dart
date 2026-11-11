// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Patch ids come from the server and are NOT covered by the patch signature, yet the client uses
/// them as directory and file names. Only the canonical lowercase UUID the server generates
/// (`str(uuid.uuid4())`) is accepted, so an id can never name a path such as `../..` (SEC-01).
///
/// Must match `OtaPaths.isValidPatchId` in the Android code.
final RegExp _patchIdPattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

bool isValidPatchId(String id) => _patchIdPattern.hasMatch(id);
