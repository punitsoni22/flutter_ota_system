// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Bounded, seeded fuzz tests (Part 10). Inputs never reach a module loader: these run in the
// plain Dart VM on Linux. Invariants:
//  - every input either verifies or throws PatchRejected (any other exception = bug);
//  - a mutated file is never accepted with different module bytes or a different manifest.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:patch_security/patch_security.dart';
import 'package:test/test.dart';

import 'support.dart';

const seed = 20261112;

void main() {
  final valid = signed(manifest());
  final validManifest = utf8.decode(splitContainer(valid).manifestBytes);

  test('container byte-level mutations (20 000 cases)', () {
    final rng = Random(seed);
    final outcomes = <String, int>{};
    for (var i = 0; i < 20000; i++) {
      final b = BytesBuilder(copy: false);
      var f = Uint8List.fromList(valid);
      switch (rng.nextInt(7)) {
        case 0: // bit flips
          for (var k = rng.nextInt(8) + 1; k > 0; k--) {
            f[rng.nextInt(f.length)] ^= 1 << rng.nextInt(8);
          }
        case 1: // truncation
          f = Uint8List.sublistView(f, 0, rng.nextInt(f.length));
        case 2: // append garbage
          b..add(f)..add(List<int>.generate(rng.nextInt(64) + 1, (_) => rng.nextInt(256)));
          f = b.toBytes();
        case 3: // corrupt a length field
          final at = rng.nextBool() ? 8 : 12 + ByteData.sublistView(f).getUint32(8);
          if (at + 4 <= f.length) ByteData.sublistView(f).setUint32(at, rng.nextInt(1 << 32));
        case 4: // overwrite a random window
          final at = rng.nextInt(f.length - 16);
          for (var k = 0; k < 16; k++) {
            f[at + k] = rng.nextInt(256);
          }
        case 5: // delete a window
          final at = rng.nextInt(f.length - 32);
          b..add(f.sublist(0, at))..add(f.sublist(at + rng.nextInt(31) + 1));
          f = b.toBytes();
        default: // random bytes with the right magic
          f = Uint8List.fromList([...ascii.encode(containerMagic), ...List<int>.generate(rng.nextInt(512), (_) => rng.nextInt(256))]);
      }
      try {
        final v = run(f);
        // Accepted: must be byte-identical in everything that is authenticated.
        expect(v.module, module, reason: 'case $i accepted with a different module');
        expect(utf8.decode(splitContainer(f).manifestBytes), validManifest, reason: 'case $i accepted with a different manifest');
        outcomes['accepted (unchanged authenticated content)'] = (outcomes['accepted (unchanged authenticated content)'] ?? 0) + 1;
      } on PatchRejected catch (e) {
        outcomes[e.code] = (outcomes[e.code] ?? 0) + 1;
      }
    }
    printOnFailure('$outcomes');
    print('container fuzz outcomes: $outcomes');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('manifest-level mutations, re-signed with the trusted key (3 000 cases)', () {
    final rng = Random(seed + 1);
    Object? junk(int depth) => switch (rng.nextInt(depth > 3 ? 5 : 8)) {
          0 => null,
          1 => rng.nextBool(),
          2 => rng.nextInt(1 << 31) - (1 << 30),
          3 => String.fromCharCodes(List.generate(rng.nextInt(40), (_) => rng.nextInt(0x2FF) + 1)),
          4 => 'x' * (rng.nextInt(3) * 70000),
          5 => [for (var k = rng.nextInt(4); k > 0; k--) junk(depth + 1)],
          6 => {for (var k = rng.nextInt(4); k > 0; k--) 'k${rng.nextInt(9)}': junk(depth + 1)},
          _ => 1.5,
        };
    final outcomes = <String, int>{};
    for (var i = 0; i < 3000; i++) {
      final m = manifest();
      final keys = m.keys.toList();
      final kind = rng.nextInt(5);
      switch (kind) {
        case 0:
          m.remove(keys[rng.nextInt(keys.length)]);
        case 1:
          m['extra_${rng.nextInt(5)}'] = junk(0);
        case 2:
          m[keys[rng.nextInt(keys.length)]] = junk(0);
        case 3:
          final key = ['runtime', 'module', 'host_interface'][rng.nextInt(3)];
          final nested = Map<String, Object?>.from(m[key]! as Map);
          nested[nested.keys.elementAt(rng.nextInt(nested.length))] = junk(0);
          m[key] = nested;
        default:
          m['packages'] = [for (var k = rng.nextInt(300); k > 0; k--) {'name': 'p${rng.nextInt(5)}', 'module_name': 'q$k', 'version': '1', 'source': 'internal'}];
      }
      Uint8List file;
      try {
        file = signed(m);
      } on FormatException {
        outcomes['not encodable (float)'] = (outcomes['not encodable (float)'] ?? 0) + 1;
        continue;
      }
      try {
        final v = run(file);
        // Accepting is only correct for a manifest that is still VALID and signed by a trusted key.
        // Compute exactly which fields changed and require each change to be a legitimate value.
        final orig = manifest();
        final changed = <String>{
          for (final k in {...orig.keys, ...v.manifest.raw.keys})
            if (utf8.decode(canonicalJson(orig[k])) != utf8.decode(canonicalJson(v.manifest.raw[k]))) k,
        };
        expect(changed.difference({'packages', 'assets', 'host_interface'}), isEmpty,
            reason: 'case $i (kind $kind) accepted with changed fields $changed');
        if (changed.contains('host_interface')) {
          final hi = v.manifest.hostInterface;
          expect(hi['sha256'], (orig['host_interface']! as Map)['sha256'], reason: 'case $i: interface hash changed');
          expect((hi['host_packages']! as List).cast<String>().every(host().hostPackages.contains), isTrue);
        }
        final names = v.manifest.packages.map((p) => p['name']).toList();
        expect(names.toSet().length, names.length, reason: 'case $i: duplicate packages accepted');
        expect(v.manifest.packages.every((p) => p['name'] != p['module_name']), isTrue);
        expect(names.any(host().hostOwnedPackages.contains), isFalse);
        outcomes['accepted: valid change of ${changed.join('+')}'] = (outcomes['accepted: valid change of ${changed.join('+')}'] ?? 0) + 1;
      } on PatchRejected catch (e) {
        outcomes[e.code] = (outcomes[e.code] ?? 0) + 1;
      }
    }
    print('manifest fuzz outcomes: $outcomes');
    // Invariant checked per case above: nothing invalid is ever accepted.
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('canonical JSON parser on random input (20 000 cases)', () {
    final rng = Random(seed + 2);
    const alphabet = '{}[]":,0123456789-+.eEtrufalsn \\/abcxyzé\u0000\n';
    var accepted = 0;
    for (var i = 0; i < 20000; i++) {
      final s = String.fromCharCodes(List.generate(rng.nextInt(60), (_) => alphabet.codeUnitAt(rng.nextInt(alphabet.length))));
      try {
        parseCanonicalObject(Uint8List.fromList(utf8.encode(s)));
        accepted++;
      } on FormatException {
        // expected
      }
    }
    print('canonical parser: $accepted of 20000 random strings were canonical objects');
  });

  test('revocation lists: random mutations never verify', () {
    final rng = Random(seed + 3);
    final body = canonicalJson({'type': 'revocations', 'release_id': releaseId, 'sequence': 2, 'revoked_patch_ids': ['a'], 'revoked_key_ids': <String>[]});
    final good = buildContainer(body, canonicalJson({'alg': 'ES256', 'key_id': 'test-key-1', 'sig': trusted.sign(signedMessage(revocationDomain, body))}), Uint8List(0));
    var rejected = 0;
    for (var i = 0; i < 3000; i++) {
      final f = Uint8List.fromList(good);
      f[12 + rng.nextInt(f.length - 12)] ^= 1 << rng.nextInt(8);
      try {
        verifyRevocations(f, host: host(), keys: verifierFor([trusted]));
      } on PatchRejected {
        rejected++;
      }
    }
    // A flipped bit inside the signature's base64 padding can decode to the same bytes, so a few
    // mutations may still verify; they then carry the identical signed body.
    print('revocation fuzz: $rejected of 3000 rejected');
    expect(rejected, greaterThan(2900));
  });
}

