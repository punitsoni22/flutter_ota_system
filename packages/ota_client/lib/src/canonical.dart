import 'dart:convert';
import 'dart:typed_data';

/// Canonical patch message from ADR-0002. Must match backend/app/canonical.py byte for byte.
class SignedFields {
  const SignedFields({
    required this.applicationId,
    required this.releaseId,
    required this.patchNumber,
    required this.platform,
    required this.arch,
    required this.runtimeAbi,
    required this.artifactFormat,
    required this.baseArtifactSha256,
    required this.payloadSha256,
    required this.resultSha256,
    required this.sizeBytes,
    this.protocolVersion = '1',
  });

  final String protocolVersion;
  final String applicationId;
  final String releaseId;
  final int patchNumber;
  final String platform;
  final String arch;
  final String runtimeAbi;
  final String artifactFormat;
  final String baseArtifactSha256;
  final String payloadSha256;
  final String resultSha256;
  final int sizeBytes;

  static final _prefix = ascii.encode('OTA-PATCH-V1\n');

  Uint8List message() {
    final out = BytesBuilder(copy: false)..add(_prefix);
    for (final field in [
      protocolVersion,
      applicationId,
      releaseId,
      '$patchNumber',
      platform,
      arch,
      runtimeAbi,
      artifactFormat,
      baseArtifactSha256.toLowerCase(),
      payloadSha256.toLowerCase(),
      resultSha256.toLowerCase(),
      '$sizeBytes',
    ]) {
      final bytes = utf8.encode(field);
      out.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
      out.add(bytes);
    }
    return out.toBytes();
  }
}
