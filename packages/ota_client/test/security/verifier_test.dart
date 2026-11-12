// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_ota_system/src/security/security.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Matcher rejectedWith(String code) =>
    throwsA(isA<PatchRejected>().having((e) => e.code, 'code', code));

Uint8List flip(Uint8List b, int index) => Uint8List.fromList(b)..[index] ^= 0x01;

void main() {
  group('accepts', () {
    test('valid signed patch', () {
      final v = run(signed(manifest()));
      expect(v.manifest.sequence, 5);
      expect(v.module, module);
    });
    test('second trusted key', () {
      expect(run(signed(manifest(keyId: 'test-key-2'), key: otherTrusted)).manifest.keyId, 'test-key-2');
    });
    test('the active patch is accepted again at start-up (reinstall)', () {
      final st = DeviceSecurityState(highestSequence: 5, activePatchId: '11111111-2222-4333-8444-555555555555');
      expect(run(signed(manifest()), state: st, reinstall: true).manifest.sequence, 5);
    });
  });

  group('rejects (Part 3.3)', () {
    test('invalid signature (bit flipped in the signature)', () {
      final m = manifest();
      final body = canonicalJson(m);
      final good = trusted.sign(signedMessage(manifestDomain, body));
      final raw = base64.decode(good)..[10] ^= 1;
      final file = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': 'test-key-1', 'sig': base64.encode(raw)}), module);
      expect(() => run(file), rejectedWith('bad_signature'));
    });
    test('modified manifest after signing', () {
      final file = signed(manifest());
      // The manifest starts at byte 12. Change "sequence":5 to "sequence":9: still valid canonical
      // JSON, so only the signature can catch it.
      final mLen = ByteData.sublistView(file).getUint32(8);
      final text = utf8.decode(file.sublist(12, 12 + mLen));
      final at = text.indexOf('"sequence":5');
      expect(at, greaterThan(0));
      final copy = Uint8List.fromList(file)..[12 + at + '"sequence":'.length] = '9'.codeUnitAt(0);
      expect(() => run(copy), rejectedWith('bad_signature'));
    });
    test('modified bytecode', () => expect(() => run(flip(signed(manifest()), signed(manifest()).length - 100)), rejectedWith('bad_hash')));
    test('wrong signing key (trusted id, other key)', () => expect(() => run(signed(manifest(), key: untrusted)), rejectedWith('bad_signature')));
    test('unknown key id', () => expect(() => run(signed(manifest(keyId: 'x'), key: TestKey('x', 5))), rejectedWith('unknown_key')));
    test('revoked key', () => expect(() => run(signed(manifest()), state: DeviceSecurityState(revokedKeyIds: {'test-key-1'})), rejectedWith('revoked_key')));
    test('signature block names another key than the manifest', () {
      final m = manifest();
      final body = canonicalJson(m);
      final file = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': 'test-key-2', 'sig': otherTrusted.sign(signedMessage(manifestDomain, body))}), module);
      expect(() => run(file), rejectedWith('key_mismatch'));
    });
    test('signature from another domain (revocation-list signature reused)', () {
      expect(() => run(signed(manifest(), domain: revocationDomain)), rejectedWith('bad_signature'));
    });
    test('wrong application id', () => expect(() => run(signed(manifest()..['app_id'] = '00000000-0000-4000-8000-000000000000')), rejectedWith('wrong_app')));
    test('wrong store release', () => expect(() => run(signed(manifest()..['release_id'] = '00000000-0000-4000-8000-000000000000')), rejectedWith('wrong_release')));
    test('wrong baseline libapp.so', () => expect(() => run(signed(manifest()..['baseline_libapp_sha256'] = 'c' * 64)), rejectedWith('wrong_baseline')));
    test('wrong engine version', () {
      final m = manifest();
      (m['runtime']! as Map)['engine'] = '00000000';
      expect(() => run(signed(m)), rejectedWith('wrong_runtime'));
    });
    test('wrong module format', () {
      final m = manifest();
      (m['module']! as Map)['format'] = 'kernel';
      expect(() => run(signed(m)), rejectedWith('bad_manifest'));
    });
    test('wrong container format (v1 file)', () {
      final f = signed(manifest());
      final v1 = Uint8List.fromList(f)..setRange(0, 8, ascii.encode('OTAPRT01'));
      expect(() => run(v1), rejectedWith('bad_magic'));
    });
    test('wrong module size in manifest', () {
      final m = manifest();
      (m['module']! as Map)['size'] = module.length + 1;
      expect(() => run(signed(m)), rejectedWith('wrong_size'));
    });
    test('missing module', () => expect(() => run(signed(manifest(), moduleBytes: Uint8List(0))), rejectedWith('missing_module')));
    test('truncated module', () {
      final f = signed(manifest());
      expect(() => run(Uint8List.sublistView(f, 0, f.length - 1000)), rejectedWith('wrong_size'));
    });
    test('truncated inside the manifest', () => expect(() => run(Uint8List.sublistView(signed(manifest()), 0, 100)), rejectedWith('truncated')));
    test('replayed older patch', () => expect(() => run(signed(manifest(sequence: 3)), state: DeviceSecurityState(highestSequence: 5)), rejectedWith('replay')));
    test('same patch replayed when not active', () => expect(() => run(signed(manifest()), state: DeviceSecurityState(highestSequence: 5)), rejectedWith('replay')));
    test('expired patch', () => expect(() => run(signed(manifest()..['expires_at'] = '2026-11-01T00:00:00Z')), rejectedWith('expired')));
    test('revoked patch id', () => expect(() => run(signed(manifest()), state: DeviceSecurityState(revokedPatchIds: {'11111111-2222-4333-8444-555555555555'})), rejectedWith('revoked')));
    test('blacklisted patch', () => expect(() => run(signed(manifest()), state: DeviceSecurityState(blacklist: {'11111111-2222-4333-8444-555555555555'})), rejectedWith('blacklisted')));
    test('host-owned package inside the module', () {
      final m = manifest();
      (m['packages']! as List).add({'name': 'app_models', 'module_name': 'app_models_patch1', 'version': '1.0.0', 'source': 'internal'});
      expect(() => run(signed(m)), rejectedWith('host_owned_package'));
    });
    test('package not renamed', () {
      final m = manifest();
      ((m['packages']! as List).first as Map)['module_name'] = 'feature_catalog';
      expect(() => run(signed(m)), rejectedWith('unrenamed_package'));
    });
    test('host package missing in this build', () {
      final m = manifest();
      ((m['host_interface']! as Map)['host_packages'] as List).add('native_crypto');
      expect(() => run(signed(m)), rejectedWith('missing_host_package'));
    });
    test('other dynamic interface', () {
      final m = manifest();
      (m['host_interface']! as Map)['sha256'] = 'd' * 64;
      expect(() => run(signed(m)), rejectedWith('wrong_interface'));
    });
    test('unknown manifest field', () => expect(() => run(signed(manifest()..['extra'] = 1)), rejectedWith('bad_manifest')));
    test('missing manifest field', () => expect(() => run(signed(manifest()..remove('sequence'))), rejectedWith('bad_manifest')));
    test('duplicate package', () {
      final m = manifest();
      final p = m['packages']! as List<Object?>;
      m['packages'] = [...p, Map<String, Object?>.from(p.first! as Map)];
      expect(() => run(signed(m)), rejectedWith('bad_manifest'));
    });
    test('asset path traversal', () {
      expect(() => run(signed(manifest()..['assets'] = [{'key': '../../files/ota/active', 'sha256': 'e' * 64, 'size': 1}])), rejectedWith('bad_manifest'));
    });
    test('non-canonical manifest (whitespace)', () {
      final body = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(manifest())));
      final file = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': 'test-key-1', 'sig': trusted.sign(signedMessage(manifestDomain, body))}), module);
      expect(() => run(file), rejectedWith('bad_manifest'));
    });
    test('duplicate JSON key in manifest', () {
      final body = Uint8List.fromList(utf8.encode(utf8.decode(canonicalJson(manifest())).replaceFirst('{', '{"app_id":"x",')));
      final file = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': 'test-key-1', 'sig': trusted.sign(signedMessage(manifestDomain, body))}), module);
      expect(() => run(file), rejectedWith('bad_manifest'));
    });
    test('oversized file', () => expect(() => run(Uint8List(maxContainerBytes + 1)), rejectedWith('too_large')));
    test('huge manifest length field', () {
      final f = Uint8List.fromList(signed(manifest()));
      ByteData.sublistView(f).setUint32(8, 0xFFFFFFFF);
      expect(() => run(f), rejectedWith('bad_manifest_length'));
    });
  });

  group('revocation list', () {
    test('valid list verifies; tampered list does not', () {
      final body = canonicalJson({'type': 'revocations', 'release_id': releaseId, 'sequence': 2, 'revoked_patch_ids': ['p'], 'revoked_key_ids': <String>[]});
      final sig = canonicalJson({'alg': 'ES256', 'key_id': 'test-key-1', 'sig': trusted.sign(signedMessage(revocationDomain, body))});
      final ok = verifyRevocations(buildContainer(body, sig, Uint8List(0)), host: host(), keys: verifierFor([trusted]));
      expect(ok.patchIds, {'p'});
      final bad = Uint8List.fromList(buildContainer(body, sig, Uint8List(0)))..[30] ^= 1;
      expect(() => verifyRevocations(bad, host: host(), keys: verifierFor([trusted])), throwsA(isA<PatchRejected>()));
    });
    test('patch signature cannot be used as a revocation list', () {
      final body = canonicalJson({'type': 'revocations', 'release_id': releaseId, 'sequence': 2, 'revoked_patch_ids': <String>[], 'revoked_key_ids': <String>[]});
      final sig = canonicalJson({'alg': 'ES256', 'key_id': 'test-key-1', 'sig': trusted.sign(signedMessage(manifestDomain, body))});
      expect(() => verifyRevocations(buildContainer(body, sig, Uint8List(0)), host: host(), keys: verifierFor([trusted])), throwsA(isA<PatchRejected>()));
    });
  });
}
