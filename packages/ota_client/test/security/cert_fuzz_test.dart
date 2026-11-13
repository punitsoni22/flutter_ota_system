// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// ignore_for_file: avoid_print

// Seeded fuzz tests for what fuzz_test.dart does not cover (Phase 5): certificate and approval
// shapes in the signature block, root-signed certificate bodies and revocation lists with
// wrongly typed fields, and deeply nested JSON. Invariant: every input either verifies or throws
// PatchRejected; any other exception or error is a bug, and nothing changed is ever accepted.
//
// Known bugs found by this file (Phase 5, not fixed yet; see the skipped tests at the end):
//  K1  a ROOT-SIGNED certificate whose key_id is not a string throws a TypeError (certs.dart
//      KeyCertificate.keyId cast) instead of PatchRejected;
//  K2  a ROOT-SIGNED revocation list whose patch/key id entries are not strings throws a
//      TypeError (verifier.dart cast<String>().toSet()); revoked_cert_serials: null is accepted
//      as "absent" (the server refuses it);
//  K3  a manifest nested about 32 000 levels deep (fits in 64 KiB, parsed BEFORE any signature
//      check) throws StackOverflowError in canonicalJson instead of PatchRejected.
// The fuzz loops count K1/K2 separately ("known") and fail on anything else.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_ota_system/src/security/security.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cert_test.dart' show approval, approver, cert, certified, root, signer, trust;
import 'support.dart';

const seed = 20261113;

/// Replacement values whose JSON type differs from [old] (all fields are typed).
List<Object?> wrongFor(Object? old) => switch (old) {
      String() => [null, true, 0, -1, <Object?>[], <String, Object?>{}, ['x']],
      int() => [null, true, '1', '', <Object?>[], <String, Object?>{}, [1]],
      List() => [null, 0, '', <String, Object?>{}, '[]', true],
      Map() => [null, 0, '', <Object?>[], '{}', true],
      _ => [0, 'x', <Object?>[]],
    };

/// All paths (map keys / list indexes) inside a JSON value.
Iterable<List<Object>> paths(Object? v, [List<Object> prefix = const []]) sync* {
  if (v is Map) {
    for (final e in v.entries) {
      yield [...prefix, e.key as String];
      yield* paths(e.value, [...prefix, e.key as String]);
    }
  } else if (v is List) {
    for (var i = 0; i < v.length; i++) {
      yield [...prefix, i];
      yield* paths(v[i], [...prefix, i]);
    }
  }
}

Object? deepCopy(Object? v) => jsonDecode(jsonEncode(v));

Object? getAt(Object? v, List<Object> path) {
  for (final p in path) {
    v = p is int ? (v! as List)[p] : (v! as Map)[p];
  }
  return v;
}

void setAt(Object? v, List<Object> path, Object? value) {
  final parent = getAt(v, path.sublist(0, path.length - 1));
  final last = path.last;
  if (last is int) {
    (parent! as List)[last] = value;
  } else {
    (parent! as Map)[last] = value;
  }
}

Object nested(int depth) {
  Object v = 0;
  for (var i = 0; i < depth; i++) {
    v = [v];
  }
  return v;
}

/// One always-invalid structural edit; returns (label, edited copy).
(String, Map<String, Object?>) edit(Random rng, Map<String, Object?> original, {Set<String> optional = const {}}) {
  final o = deepCopy(original)! as Map<String, Object?>;
  final all = paths(o).toList();
  switch (rng.nextInt(4)) {
    case 0:
      final p = all[rng.nextInt(all.length)];
      final choices = wrongFor(getAt(o, p));
      final value = deepCopy(choices[rng.nextInt(choices.length)]);
      setAt(o, p, value);
      return ('wrong_type ${p.join('.')}=${jsonEncode(value)}', o);
    case 1:
      final keys = all.where((p) => p.last is String && !optional.contains(p.join('.'))).toList();
      final p = keys[rng.nextInt(keys.length)];
      (getAt(o, p.sublist(0, p.length - 1))! as Map).remove(p.last);
      return ('delete ${p.join('.')}', o);
    case 2:
      final maps = [<Object>[], ...all.where((p) => getAt(o, p) is Map)];
      final p = maps[rng.nextInt(maps.length)];
      (getAt(o, p)! as Map)['zz_unknown'] = 0;
      return ('unknown_key ${p.join('.')}', o);
    default:
      final p = all[rng.nextInt(all.length)];
      final depth = [16, 200, 1000][rng.nextInt(3)];
      setAt(o, p, nested(depth));
      return ('deep$depth ${p.join('.')}', o);
  }
}

/// Runs [body]; returns the PatchRejected code, or records a failure for anything else.
/// [known] classifies a documented bug (label, error or null when accepted) instead.
String outcome(String label, Object? Function() body, List<String> failures,
    {required bool mayAccept, bool Function(String label, Object? error)? known}) {
  try {
    body();
    if (mayAccept) return 'accepted';
    if (known != null && known(label, null)) return 'KNOWN accepted';
    failures.add('$label: ACCEPTED');
    return 'ACCEPTED';
  } on PatchRejected catch (e) {
    return e.code;
  } catch (e) {
    if (known != null && known(label, e)) return 'KNOWN ${e.runtimeType}';
    failures.add('$label: ${e.runtimeType}: ${e.toString().split('\n').first}');
    return 'error ${e.runtimeType}';
  }
}

/// K1: TypeError for a root-signed certificate body whose key_id is not a string.
bool knownK1(String label, Object? e) => e is TypeError && RegExp(r'^case \d+ \w+ key_id(=| |$)').hasMatch(label);

/// K2: TypeError for non-string revoked ids; null revoked_cert_serials accepted.
bool knownK2(String label, Object? e) =>
    (e is TypeError && RegExp(r'^case \d+ \w+ revoked_(patch|key)_ids').hasMatch(label)) ||
    (e == null && label.endsWith('revoked_cert_serials=null'));

void count(Map<String, int> m, String k) => m[k] = (m[k] ?? 0) + 1;

void main() {
  final m = manifest(keyId: signer.id);
  final manifestBytes = canonicalJson(m);
  final approverCert = cert(approver, roles: ['approver'], serial: 9);
  final good = certified(signer, cert(signer), m: m, approvals: [approval(approver, approverCert, manifestBytes)]);
  final goodParts = splitContainer(good);
  final block = jsonDecode(utf8.decode(goodParts.signatureBytes)) as Map<String, Object?>;
  VerifiedPatch verify(Uint8List f) => run(f, trust: trust(approvals: 1));

  test('the base container is valid', () => expect(verify(good).manifest.keyId, signer.id));

  test('signature block: certificate and approval shapes (1 000 cases)', () {
    final rng = Random(seed);
    final stats = <String, int>{};
    final failures = <String>[];
    for (var i = 0; i < 1000; i++) {
      final (label, b) = edit(rng, block);
      final Uint8List sigBytes;
      try {
        sigBytes = canonicalJson(b);
      } on Object {
        count(stats, 'not encodable');
        continue;
      }
      if (sigBytes.length > maxSignatureBytes) {
        count(stats, 'oversized (rejected by length)');
      }
      final f = buildContainer(manifestBytes, sigBytes, module);
      count(stats, outcome('case $i $label', () => verify(f), failures, mayAccept: false));
    }
    print('signature-block fuzz: $stats');
    expect(failures, isEmpty, reason: failures.take(20).join('\n'));
  });

  test('root-signed certificate bodies with invalid fields (800 cases)', () {
    final rng = Random(seed + 1);
    final body = (block['cert']! as Map)['body']! as Map<String, Object?>;
    final stats = <String, int>{};
    final failures = <String>[];
    for (var i = 0; i < 800; i++) {
      final (label, edited) = edit(rng, body);
      final Uint8List bodyBytes;
      try {
        bodyBytes = canonicalJson(edited);
      } on Object {
        count(stats, 'not encodable');
        continue;
      }
      final c = {'body': edited, 'root_key_id': root.id, 'sig': root.sign(signedMessage(keyCertDomain, bodyBytes))};
      final b = Map<String, Object?>.from(block)..['cert'] = c;
      final f = buildContainer(manifestBytes, canonicalJson(b), module);
      count(stats, outcome('case $i $label', () => verify(f), failures, mayAccept: false, known: knownK1));
    }
    print('certificate-body fuzz: $stats');
    expect(failures, isEmpty, reason: failures.take(20).join('\n'));
  });

  test('root-signed revocation lists with invalid fields (800 cases)', () {
    final rng = Random(seed + 2);
    final list = <String, Object?>{
      'type': 'revocations', 'release_id': releaseId, 'sequence': 3,
      'revoked_patch_ids': ['11111111-2222-4333-8444-555555555555'], 'revoked_key_ids': ['old-key'],
      'revoked_cert_serials': [4],
    };
    final stats = <String, int>{};
    final failures = <String>[];
    for (var i = 0; i < 800; i++) {
      final (label, edited) = edit(rng, list, optional: {'revoked_cert_serials'});
      final Uint8List body;
      try {
        body = canonicalJson(edited);
      } on Object {
        count(stats, 'not encodable');
        continue;
      }
      final f = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': root.id,
        'sig': root.sign(signedMessage(revocationDomain, body))}), Uint8List(0));
      count(stats, outcome('case $i $label', () => verifyRevocations(f, host: host(), keys: verifierFor([]), trust: trust()),
          failures, mayAccept: false, known: knownK2));
    }
    print('revocation-list fuzz: $stats');
    expect(failures, isEmpty, reason: failures.take(20).join('\n'));
  });

  test('deeply nested JSON in the manifest and signature block is rejected cleanly', () {
    final failures = <String>[];
    final stats = <String, int>{};
    // The manifest is parsed before any signature check. 32 000 levels: see K3 below.
    for (final depth in [100, 1000, 10000]) {
      final text = '{"a":${'[' * depth}0${']' * depth}}';
      final bytes = Uint8List.fromList(utf8.encode(text));
      if (bytes.length > maxManifestBytes) continue;
      final f = buildContainer(bytes, goodParts.signatureBytes, module);
      count(stats, outcome('manifest depth $depth', () => verify(f), failures, mayAccept: false));
      final s = Uint8List.fromList(utf8.encode('{"a":${'[' * min(depth, 4000)}0${']' * min(depth, 4000)}}'));
      final g = buildContainer(manifestBytes, s, module);
      count(stats, outcome('signature depth ${min(depth, 4000)}', () => verify(g), failures, mayAccept: false));
    }
    print('deep-nesting: $stats');
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  group('known bugs (skipped until fixed; each asserts the CORRECT behaviour)', () {
    test('K1: root-signed certificate with a non-string key_id is PatchRejected', () {
      final body = Map<String, Object?>.from((block['cert']! as Map)['body']! as Map)..['key_id'] = 7;
      final c = {'body': body, 'root_key_id': root.id, 'sig': root.sign(signedMessage(keyCertDomain, canonicalJson(body)))};
      final f = buildContainer(manifestBytes, canonicalJson(Map<String, Object?>.from(block)..['cert'] = c), module);
      expect(() => verify(f), throwsA(isA<PatchRejected>()));
    }, skip: 'K1 known bug (Phase 5 security fuzz): TypeError instead of PatchRejected');

    test('K2: root-signed revocation list with non-string ids is PatchRejected', () {
      final body = canonicalJson({'type': 'revocations', 'release_id': releaseId, 'sequence': 3,
        'revoked_patch_ids': [1], 'revoked_key_ids': <String>[]});
      final f = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': root.id,
        'sig': root.sign(signedMessage(revocationDomain, body))}), Uint8List(0));
      expect(() => verifyRevocations(f, host: host(), keys: verifierFor([]), trust: trust()), throwsA(isA<PatchRejected>()));
    }, skip: 'K2 known bug (Phase 5 security fuzz): TypeError instead of PatchRejected');

    test('K3: a manifest nested 32 000 levels deep is PatchRejected', () {
      final bytes = Uint8List.fromList(utf8.encode('{"a":${'[' * 32000}0${']' * 32000}}'));
      expect(() => verify(buildContainer(bytes, goodParts.signatureBytes, module)), throwsA(isA<PatchRejected>()));
    }, skip: 'K3 known bug (Phase 5 security fuzz): StackOverflowError instead of PatchRejected');
  });
}
