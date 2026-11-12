// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// A patch offered by the Flutter OTA System server: what it is, where to download it, and the
/// hashes and ES256 signature that the client checks before using it.
///
/// Apps read it through [OtaClient.activePatch] (e.g. to show `#${patch.number}` in a debug
/// screen). Custom [PatchRuntime]s receive it in `stage` and `load`.
class PatchRecord {
  /// Creates a patch description. Apps normally get instances from the client, not by
  /// constructing them.
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

  /// Server id of the patch: a lowercase UUID. Not covered by the signature (protocol v1); the
  /// client refuses any other format.
  final String id;

  /// Patch number within its release (1, 2, 3, …). Higher is newer.
  final int number;

  /// Payload format, e.g. `mock-v1` or `aot-bidiff-android-v1`.
  final String artifactFormat;

  /// CPU ABI the patch is built for, e.g. `arm64-v8a`.
  final String arch;

  /// Runtime ABI of the release, e.g. `ota-runtime-v1`; must match the app's [PatchRuntime].
  final String runtimeAbi;

  /// Where the payload is downloaded from. Must be `https://` in release builds.
  final String downloadUrl;

  /// SHA-256 (hex) of the store artifact the patch applies to (code patches).
  final String baseArtifactSha256;

  /// SHA-256 (hex) of the downloaded payload.
  final String payloadSha256;

  /// SHA-256 (hex) of the result after applying the payload (code patches: the rebuilt
  /// `libapp.so`; `mock-v1`: equal to [payloadSha256]).
  final String resultSha256;

  /// Exact payload size in bytes. Downloads that exceed or fall short of it are refused.
  final int sizeBytes;

  /// ES256 signature (base64, raw r||s) over the canonical patch message.
  final String signature;

  /// Id of the signing key; must be one of [OtaConfig.publicKeys].
  final String keyId;
}

/// What happened during [OtaClient.checkForUpdate], for the app's UI or logs.
enum UpdateStatus {
  /// Nothing new.
  upToDate,

  /// A patch was downloaded, verified and staged. It runs after the next app restart.
  stagedRestartRequired,

  /// The current patch was rolled back or revoked. The fallback runs after the next restart.
  rollbackRestartRequired,

  /// The server offered something this client refused (bad hash/signature, replay, unknown
  /// format, invalid patch id, insecure URL, wrong application). See [UpdateResult.message].
  rejected,

  /// Network or server problem, a timeout, or a refused server URL. The app keeps running its
  /// current code. See [UpdateResult.message].
  failed,
}

/// Result of [OtaClient.checkForUpdate]. The check never throws; problems are reported here.
class UpdateResult {
  /// Creates a result. Apps normally receive results from the client.
  const UpdateResult(this.status, {this.patchNumber, this.message});

  /// What happened.
  final UpdateStatus status;

  /// The patch concerned (staged, refused or rollback target), if any.
  final int? patchNumber;

  /// Human-readable detail for logs, e.g. `signature invalid` or a timeout. Not a stable API:
  /// do not parse it.
  final String? message;

  @override
  String toString() =>
      'UpdateResult(${status.name}${patchNumber != null ? ', patch $patchNumber' : ''}'
      '${message != null ? ', $message' : ''})';
}
