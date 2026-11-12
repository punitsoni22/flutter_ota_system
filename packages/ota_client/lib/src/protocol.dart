// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Wire format of the device API (GET /v1/updates/check). Internal: not exported.

import 'models.dart';

PatchRecord patchRecordFromJson(Map<String, dynamic> j) => PatchRecord(
  id: j['id'] as String,
  number: j['number'] as int,
  artifactFormat: j['artifact_format'] as String,
  arch: j['arch'] as String,
  runtimeAbi: j['runtime_abi'] as String,
  downloadUrl: j['download_url'] as String,
  baseArtifactSha256: j['base_artifact_sha256'] as String,
  payloadSha256: j['payload_sha256'] as String,
  resultSha256: j['result_sha256'] as String,
  sizeBytes: j['size_bytes'] as int,
  signature: j['signature'] as String,
  keyId: j['key_id'] as String,
);

Map<String, dynamic> patchRecordToJson(PatchRecord p) => {
  'id': p.id,
  'number': p.number,
  'artifact_format': p.artifactFormat,
  'arch': p.arch,
  'runtime_abi': p.runtimeAbi,
  'download_url': p.downloadUrl,
  'base_artifact_sha256': p.baseArtifactSha256,
  'payload_sha256': p.payloadSha256,
  'result_sha256': p.resultSha256,
  'size_bytes': p.sizeBytes,
  'signature': p.signature,
  'key_id': p.keyId,
};

class UpdateCheckResponse {
  const UpdateCheckResponse({
    required this.updateAvailable,
    required this.applicationId,
    required this.releaseId,
    required this.patch,
    required this.rollbackToPatchNumber,
    required this.rolledBackPatchNumbers,
    required this.revokedPatchNumbers,
    required this.nextCheckAfterSeconds,
  });

  final bool updateAvailable;
  final String applicationId;
  final String? releaseId;
  final PatchRecord? patch;
  final int? rollbackToPatchNumber;
  final List<int> rolledBackPatchNumbers;
  final List<int> revokedPatchNumbers;
  final int nextCheckAfterSeconds;

  Set<int> get badPatchNumbers => {...rolledBackPatchNumbers, ...revokedPatchNumbers};

  factory UpdateCheckResponse.fromJson(Map<String, dynamic> j) => UpdateCheckResponse(
    updateAvailable: j['update_available'] as bool,
    applicationId: j['application_id'] as String,
    releaseId: j['release_id'] as String?,
    patch: j['patch'] == null ? null : patchRecordFromJson(j['patch'] as Map<String, dynamic>),
    rollbackToPatchNumber: j['rollback_to_patch_number'] as int?,
    rolledBackPatchNumbers: (j['rolled_back_patch_numbers'] as List).cast<int>(),
    revokedPatchNumbers: (j['revoked_patch_numbers'] as List).cast<int>(),
    nextCheckAfterSeconds: j['next_check_after_seconds'] as int,
  );
}
