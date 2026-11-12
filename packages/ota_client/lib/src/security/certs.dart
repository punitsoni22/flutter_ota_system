// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Key certificates, rotation and approvals for developer-signed `dbc-v1` patches (ported from the
// Phase 3C `patch_security` package; logic and error codes unchanged).
//
// Trust chain (all keys ES256):
//   app ROOT key (offline; its public key is compiled into the store build)
//     -> signs a KEY CERTIFICATE for a patch-signing or approver key:
//        {type: key_cert, app_id, environment, key_id, public_key, roles, serial,
//         not_before, not_after}
//     -> the certified key signs the patch manifest (signer) or approves it (approver).
//
// Rotation = a new certificate with a new serial; the old key is retired by revoking its serial
// or key id in a signed revocation list. Only ROOT keys can issue certificates, so a stolen
// signer key cannot certify another key (unauthorised rotation).

import 'dart:typed_data';

import 'canonical.dart';
import 'container.dart';
import 'signature.dart';

const keyCertDomain = 'flutter-ota-system/key-certificate/v1\n';
const approvalDomain = 'flutter-ota-system/patch-approval/v1\n';

/// What a store build trusts: root keys per application and its environment.
class CertificateTrust {
  CertificateTrust({
    required this.roots,
    required this.environment,
    this.requiredApprovals = 0,
    this.requireCertificates = true,
  });

  /// Root public keys (key id -> base64 point) of THIS application.
  final Es256Verifier roots;
  final String environment; // e.g. "production" or "development"
  final int requiredApprovals;

  /// When true, manifests signed by a directly trusted key (no certificate) are refused.
  final bool requireCertificates;
}

class KeyCertificate {
  KeyCertificate(this.raw);
  final Map<String, Object?> raw;
  String get keyId => raw['key_id']! as String;
  String get publicKey => raw['public_key']! as String;
  int get serial => raw['serial']! as int;
  List<String> get roles => (raw['roles']! as List).cast<String>();
}

DateTime _time(Object? v, String what) {
  if (v is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(v)) {
    throw PatchRejected('bad_certificate', '$what is not a UTC timestamp');
  }
  return DateTime.parse(v);
}

/// Verifies a certificate object {body: {...}, root_key_id, sig} and returns the certified key.
KeyCertificate verifyCertificate(
  Object? cert, {
  required CertificateTrust trust,
  required String appId,
  required String role,
  required DateTime now,
  required Set<int> revokedSerials,
  required Set<String> revokedKeyIds,
}) {
  Never bad(String code, String why) => throw PatchRejected(code, why);
  if (cert is! Map || cert.keys.toSet().difference({'body', 'root_key_id', 'sig'}).isNotEmpty) {
    bad('bad_certificate', 'certificate has an invalid shape');
  }
  final body = cert['body'];
  final rootId = cert['root_key_id'];
  final sig = cert['sig'];
  if (body is! Map<String, Object?> || rootId is! String || sig is! String) {
    bad('bad_certificate', 'certificate has an invalid shape');
  }
  const fields = {'type', 'app_id', 'environment', 'key_id', 'public_key', 'roles', 'serial', 'not_before', 'not_after'};
  if (body.keys.toSet().difference(fields).isNotEmpty || !fields.every(body.containsKey)) {
    bad('bad_certificate', 'certificate body has unknown or missing fields');
  }
  if (body['type'] != 'key_cert') bad('bad_certificate', 'not a key certificate');
  // Only an application ROOT key may issue certificates (blocks unauthorised rotation).
  if (!trust.roots.knows(rootId)) bad('untrusted_root', 'certificate not issued by a root key of this application');
  final bytes = canonicalJson(body);
  if (!trust.roots.verify(rootId, signedMessage(keyCertDomain, bytes), sig)) {
    bad('bad_certificate_signature', 'certificate signature does not verify');
  }
  final c = KeyCertificate(body);
  if (body['app_id'] != appId) bad('wrong_app_key', 'certificate is for another application');
  if (body['environment'] != trust.environment) bad('wrong_environment', 'certificate is for the ${body['environment']} environment');
  final roles = body['roles'];
  if (roles is! List || !roles.contains(role)) bad('wrong_role', 'certificate does not allow the $role role');
  if (body['serial'] is! int) bad('bad_certificate', 'serial is not an integer');
  if (revokedSerials.contains(c.serial)) bad('revoked_certificate', 'certificate ${c.serial} is revoked');
  if (revokedKeyIds.contains(c.keyId)) bad('revoked_key', 'key ${c.keyId} is revoked');
  final notBefore = _time(body['not_before'], 'not_before');
  final notAfter = _time(body['not_after'], 'not_after');
  if (now.isBefore(notBefore)) bad('certificate_not_yet_valid', 'certificate is not valid yet');
  if (!now.isBefore(notAfter)) bad('expired_certificate', 'certificate expired at ${body['not_after']}');
  try {
    Es256Verifier({c.keyId: c.publicKey});
  } catch (_) {
    bad('bad_certificate', 'certificate public key is invalid');
  }
  return c;
}

/// Verifies the manifest signature through a certificate (signer role) and counts valid approvals
/// from distinct approver keys other than the signer. Throws [PatchRejected].
void verifyCertifiedSignature(
  Map<String, Object?> sigBlock,
  Uint8List manifestBytes, {
  required String manifestKeyId,
  required CertificateTrust trust,
  required String appId,
  required DateTime now,
  required Set<int> revokedSerials,
  required Set<String> revokedKeyIds,
}) {
  final cert = verifyCertificate(sigBlock['cert'],
      trust: trust, appId: appId, role: 'signer', now: now, revokedSerials: revokedSerials, revokedKeyIds: revokedKeyIds);
  if (cert.keyId != manifestKeyId || sigBlock['key_id'] != manifestKeyId) {
    throw PatchRejected('key_mismatch', 'certificate key id differs from the manifest');
  }
  final sig = sigBlock['sig'];
  if (sig is! String ||
      !Es256Verifier({cert.keyId: cert.publicKey}).verify(cert.keyId, signedMessage(manifestDomain, manifestBytes), sig)) {
    throw PatchRejected('bad_signature', 'manifest signature does not verify');
  }
  final approvals = sigBlock['approvals'] ?? const <Object?>[];
  if (approvals is! List || approvals.length > 16) throw PatchRejected('bad_approval', 'approvals must be a short list');
  final approvers = <String>{};
  for (final a in approvals) {
    if (a is! Map || a.keys.toSet().difference({'cert', 'sig'}).isNotEmpty) {
      throw PatchRejected('bad_approval', 'approval has an invalid shape');
    }
    final ac = verifyCertificate(a['cert'],
        trust: trust, appId: appId, role: 'approver', now: now, revokedSerials: revokedSerials, revokedKeyIds: revokedKeyIds);
    final asig = a['sig'];
    if (asig is! String ||
        !Es256Verifier({ac.keyId: ac.publicKey}).verify(ac.keyId, signedMessage(approvalDomain, manifestBytes), asig)) {
      throw PatchRejected('bad_approval', 'approval by ${ac.keyId} does not verify');
    }
    if (ac.keyId == cert.keyId) throw PatchRejected('bad_approval', 'the signer cannot approve its own patch');
    approvers.add(ac.keyId);
  }
  if (approvers.length < trust.requiredApprovals) {
    throw PatchRejected('approval_required', '${approvers.length} of ${trust.requiredApprovals} required approvals');
  }
}

