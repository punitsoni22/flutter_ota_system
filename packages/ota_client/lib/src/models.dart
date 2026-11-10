/// A patch the server offered, as returned by GET /v1/updates/check.
class PatchRecord {
  const PatchRecord({
    required this.id,
    required this.number,
    required this.artifactFormat,
    required this.arch,
    required this.runtimeAbi,
    required this.downloadUrl,
    required this.baseArtifactSha256,
    required this.payloadSha256,
    required this.resultSha256,
    required this.sizeBytes,
    required this.signature,
    required this.keyId,
  });

  final String id;
  final int number;
  final String artifactFormat;
  final String arch;
  final String runtimeAbi;
  final String downloadUrl;
  final String baseArtifactSha256;
  final String payloadSha256;
  final String resultSha256;
  final int sizeBytes;
  final String signature;
  final String keyId;

  factory PatchRecord.fromJson(Map<String, dynamic> j) => PatchRecord(
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'artifact_format': artifactFormat,
        'arch': arch,
        'runtime_abi': runtimeAbi,
        'download_url': downloadUrl,
        'base_artifact_sha256': baseArtifactSha256,
        'payload_sha256': payloadSha256,
        'result_sha256': resultSha256,
        'size_bytes': sizeBytes,
        'signature': signature,
        'key_id': keyId,
      };
}

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
        patch: j['patch'] == null ? null : PatchRecord.fromJson(j['patch'] as Map<String, dynamic>),
        rollbackToPatchNumber: j['rollback_to_patch_number'] as int?,
        rolledBackPatchNumbers: (j['rolled_back_patch_numbers'] as List).cast<int>(),
        revokedPatchNumbers: (j['revoked_patch_numbers'] as List).cast<int>(),
        nextCheckAfterSeconds: j['next_check_after_seconds'] as int,
      );
}

/// What happened during a check, for the app's UI or logs.
enum UpdateStatus {
  /// Nothing new.
  upToDate,

  /// A patch was downloaded, verified and staged. It runs after the next app restart.
  stagedRestartRequired,

  /// The current patch was rolled back or revoked. The fallback runs after the next restart.
  rollbackRestartRequired,

  /// The server offered something this client refused (bad hash/signature, replay, unknown format).
  rejected,

  /// Network or server problem. The app keeps running its current code.
  failed,
}

class UpdateResult {
  const UpdateResult(this.status, {this.patchNumber, this.message});
  final UpdateStatus status;
  final int? patchNumber;
  final String? message;

  @override
  String toString() =>
      'UpdateResult(${status.name}${patchNumber != null ? ', patch $patchNumber' : ''}'
      '${message != null ? ', $message' : ''})';
}
