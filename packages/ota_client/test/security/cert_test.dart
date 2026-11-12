// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 3C: key certificates, rotation, approvals (Part 8.F) and toolchain provenance (Part 7).

import 'dart:typed_data';

import 'package:flutter_ota_system/src/security/security.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final root = TestKey('root-app-1', 1001);
final otherAppRoot = TestKey('root-other-app', 1002);
final signer = TestKey('signer-2026a', 2001);
final signerNext = TestKey('signer-2026b', 2002);
final approver = TestKey('approver-1', 3001);

Matcher rejectedWith(String code) => throwsA(isA<PatchRejected>().having((e) => e.code, 'code', code));

Map<String, Object?> cert(TestKey key, {TestKey? by, String app = appId, String env = 'production',
    List<String> roles = const ['signer'], int serial = 1, String from = '2026-11-01T00:00:00Z', String to = '2026-12-31T00:00:00Z'}) {
  final issuer = by ?? root;
  final body = <String, Object?>{
    'type': 'key_cert', 'app_id': app, 'environment': env, 'key_id': key.id, 'public_key': key.publicB64,
    'roles': roles, 'serial': serial, 'not_before': from, 'not_after': to,
  };
  return {'body': body, 'root_key_id': issuer.id, 'sig': issuer.sign(signedMessage(keyCertDomain, canonicalJson(body)))};
}

CertificateTrust trust({int approvals = 0, bool require = true}) => CertificateTrust(
    roots: verifierFor([root]), environment: 'production', requiredApprovals: approvals, requireCertificates: require);

Uint8List certified(TestKey key, Map<String, Object?> c, {List<Map<String, Object?>> approvals = const [], Map<String, Object?>? m}) {
  final manifestMap = m ?? manifest(keyId: key.id);
  final body = canonicalJson(manifestMap);
  final block = <String, Object?>{
    'alg': 'ES256', 'key_id': key.id, 'sig': key.sign(signedMessage(manifestDomain, body)), 'cert': c,
    if (approvals.isNotEmpty) 'approvals': approvals,
  };
  return buildContainer(body, canonicalJson(block), module);
}

Map<String, Object?> approval(TestKey key, Map<String, Object?> c, Uint8List manifestBytes) =>
    {'cert': c, 'sig': key.sign(signedMessage(approvalDomain, manifestBytes))};

void main() {
  group('certificates (Part 8)', () {
    test('accepts a patch signed by a root-certified key', () {
      expect(run(certified(signer, cert(signer)), trust: trust()).manifest.keyId, signer.id);
    });
    test('key rotation: a newly certified key is accepted without a new store build', () {
      expect(run(certified(signerNext, cert(signerNext, serial: 2)), trust: trust()).manifest.keyId, signerNext.id);
    });
    test('wrong application key (certificate for another app)', () {
      expect(() => run(certified(signer, cert(signer, app: '00000000-0000-4000-8000-000000000000')), trust: trust()), rejectedWith('wrong_app_key'));
    });
    test('wrong application root (another app root signed the certificate)', () {
      expect(() => run(certified(signer, cert(signer, by: otherAppRoot)), trust: trust()), rejectedWith('untrusted_root'));
    });
    test('wrong environment key', () {
      expect(() => run(certified(signer, cert(signer, env: 'development')), trust: trust()), rejectedWith('wrong_environment'));
    });
    test('revoked key', () {
      expect(() => run(certified(signer, cert(signer)), trust: trust(), state: DeviceSecurityState(revokedKeyIds: {signer.id})),
          rejectedWith('revoked_key'));
    });
    test('old key used after rotation (its certificate serial revoked)', () {
      expect(() => run(certified(signer, cert(signer)), trust: trust(), state: DeviceSecurityState(revokedCertSerials: {1})),
          rejectedWith('revoked_certificate'));
    });
    test('expired certificate', () {
      expect(() => run(certified(signer, cert(signer, to: '2026-11-10T00:00:00Z')), trust: trust()), rejectedWith('expired_certificate'));
    });
    test('certificate not yet valid', () {
      expect(() => run(certified(signer, cert(signer, from: '2026-12-01T00:00:00Z')), trust: trust()), rejectedWith('certificate_not_yet_valid'));
    });
    test('unauthorised rotation: a signer key certifies another key', () {
      expect(() => run(certified(signerNext, cert(signerNext, by: signer, serial: 2)), trust: trust()), rejectedWith('untrusted_root'));
    });
    test('replayed rotation: a stolen old certificate whose serial was revoked', () {
      final old = cert(signer, serial: 1);
      expect(() => run(certified(signer, old), trust: trust(), state: DeviceSecurityState(revokedCertSerials: {1})),
          rejectedWith('revoked_certificate'));
    });
    test('tampered certificate body', () {
      final c = cert(signer);
      (c['body']! as Map)['roles'] = ['signer', 'approver']; // body changed after the root signed it
      expect(() => run(certified(signer, c), trust: trust()), rejectedWith('bad_certificate_signature'));
    });
    test('approver certificate cannot sign a patch', () {
      expect(() => run(certified(approver, cert(approver, roles: ['approver'])), trust: trust()), rejectedWith('wrong_role'));
    });
    test('uncertified key refused when certificates are required', () {
      expect(() => run(signed(manifest()), trust: trust()), rejectedWith('certificate_required'));
    });
    test('manifest key id differs from the certified key', () {
      expect(() => run(certified(signer, cert(signerNext, serial: 2)), trust: trust()), rejectedWith('key_mismatch'));
    });
  });

  group('approvals (Part 8.E)', () {
    final m = manifest(keyId: 'signer-2026a');
    final body = canonicalJson(m);
    test('production patch with the required approval is accepted', () {
      final file = certified(signer, cert(signer), m: m, approvals: [approval(approver, cert(approver, roles: ['approver'], serial: 9), body)]);
      expect(run(file, trust: trust(approvals: 1)).manifest.keyId, signer.id);
    });
    test('missing approval', () {
      expect(() => run(certified(signer, cert(signer), m: m), trust: trust(approvals: 1)), rejectedWith('approval_required'));
    });
    test('invalid approval signature (approval of another manifest)', () {
      final other = canonicalJson(manifest(keyId: 'signer-2026a', sequence: 9));
      final file = certified(signer, cert(signer), m: m, approvals: [approval(approver, cert(approver, roles: ['approver'], serial: 9), other)]);
      expect(() => run(file, trust: trust(approvals: 1)), rejectedWith('bad_approval'));
    });
    test('the signer cannot approve its own patch', () {
      final file = certified(signer, cert(signer), m: m,
          approvals: [approval(signer, cert(signer, roles: ['signer', 'approver']), body)]);
      expect(() => run(file, trust: trust(approvals: 1)), rejectedWith('bad_approval'));
    });
    test('approval by a key without the approver role', () {
      final file = certified(signer, cert(signer), m: m, approvals: [approval(signerNext, cert(signerNext, serial: 2), body)]);
      expect(() => run(file, trust: trust(approvals: 1)), rejectedWith('wrong_role'));
    });
  });

  group('toolchain provenance (Part 7)', () {
    test('patch from another compiler is refused', () {
      expect(() => run(signed(manifest()..['toolchain'] = toolchain(compiler: '9' * 64))), rejectedWith('wrong_toolchain'));
    });
    test('toolchain id that does not match its fields', () {
      final t = toolchain()..['generator_sha256'] = '2' * 64;
      expect(() => run(signed(manifest()..['toolchain'] = t)), rejectedWith('bad_toolchain'));
    });
    test('missing toolchain record', () {
      expect(() => run(signed(manifest()..remove('toolchain'))), rejectedWith('bad_manifest'));
    });
  });

  group('revocation lists signed by the root (Part 8.D)', () {
    test('root-signed list revokes certificate serials', () {
      final body = canonicalJson({'type': 'revocations', 'release_id': releaseId, 'sequence': 3,
        'revoked_patch_ids': <String>[], 'revoked_key_ids': <String>[], 'revoked_cert_serials': [1]});
      final file = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': root.id,
        'sig': root.sign(signedMessage(revocationDomain, body))}), Uint8List(0));
      final r = verifyRevocations(file, host: host(), keys: verifierFor([]), trust: trust());
      expect(r.certSerials, {1});
    });
    test('a signer key cannot revoke (not a root)', () {
      final body = canonicalJson({'type': 'revocations', 'release_id': releaseId, 'sequence': 3,
        'revoked_patch_ids': <String>[], 'revoked_key_ids': ['root-app-1']});
      final file = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': signer.id,
        'sig': signer.sign(signedMessage(revocationDomain, body))}), Uint8List(0));
      expect(() => verifyRevocations(file, host: host(), keys: verifierFor([]), trust: trust()), throwsA(isA<PatchRejected>()));
    });
  });
}
