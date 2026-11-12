// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/owner.dart';
import 'package:test/test.dart';

void main() {
  final key = Es256KeyPair.generate();
  final other = Es256KeyPair.generate();
  final src = Uri.parse('file:///mirror/index.json');
  final body = {
    'serial': 3,
    'toolchains': [
      indexEntry(
        id: 'flutter-3.47.9-ota.1',
        toolchainId: 'a' * 64,
        flutter: '3.47.9',
        dart: '3.13.7',
        engine: '89c39edfdfae2949f6806e4a315c0c08522238b7',
        dartRevision: '416e33b0ffaef062a60ec966bb8c82ed2b83f128',
        sdk: {
          'url': 'https://example.org/flutter.tar.xz',
          'sha256': 'b' * 64,
          'size': 10,
          'format': 'tar.xz',
          'root': 'flutter',
        },
        overlay: {'url': 'overlays/o.tar.gz', 'sha256': 'c' * 64, 'size': 5, 'format': 'tar.gz'},
      ),
    ],
  };

  test('a good signature verifies and relative URLs resolve against the index', () {
    final idx = ToolchainIndex.verifyAndParse(signIndex(body, 'k1', key), {'k1': key.publicKeyBase64}, src);
    expect(idx.signedBy, 'k1');
    expect(idx.serial, 3);
    expect(idx.toolchains.single.overlay.url.toString(), 'file:///mirror/overlays/o.tar.gz');
    expect(idx.toolchains.single.sdk.url.toString(), 'https://example.org/flutter.tar.xz');
  });

  test('a changed index (bad signature) is refused', () {
    final env = jsonDecode(utf8.decode(signIndex(body, 'k1', key))) as Map<String, Object?>;
    ((env['index'] as Map)['toolchains'] as List).first['toolchain_id'] = 'd' * 64;
    expect(
      () => ToolchainIndex.verifyAndParse(Uint8List.fromList(utf8.encode(jsonEncode(env))), {
        'k1': key.publicKeyBase64,
      }, src),
      throwsA(isA<IndexVerificationException>().having((e) => e.message, 'message', contains('INVALID signature'))),
    );
  });

  test('a signature by the wrong key under a trusted id is refused', () {
    expect(
      () => ToolchainIndex.verifyAndParse(signIndex(body, 'k1', other), {'k1': key.publicKeyBase64}, src),
      throwsA(isA<IndexVerificationException>()),
    );
  });

  test('an unknown key is refused', () {
    expect(
      () => ToolchainIndex.verifyAndParse(signIndex(body, 'stranger', other), {'k1': key.publicKeyBase64}, src),
      throwsA(isA<IndexVerificationException>().having((e) => e.message, 'message', contains('unknown key'))),
    );
  });

  test('no trusted keys at all: verification is not skipped', () {
    expect(
      () => ToolchainIndex.verifyAndParse(signIndex(body, 'k1', key), {}, src),
      throwsA(isA<IndexVerificationException>()),
    );
  });

  test('a signature without the toolchain-index domain prefix is refused', () {
    final sig = key.sign(canonicalJson(body)); // no domain
    final env = utf8.encode(
      jsonEncode({
        'format': 1,
        'index': body,
        'signatures': [
          {'key_id': 'k1', 'signature': sig},
        ],
      }),
    );
    expect(
      () => ToolchainIndex.verifyAndParse(Uint8List.fromList(env), {'k1': key.publicKeyBase64}, src),
      throwsA(isA<IndexVerificationException>()),
    );
  });

  test('unsigned and malformed envelopes are refused', () {
    final unsigned = utf8.encode(jsonEncode({'format': 1, 'index': body, 'signatures': []}));
    expect(
      () => ToolchainIndex.verifyAndParse(Uint8List.fromList(unsigned), {'k1': key.publicKeyBase64}, src),
      throwsA(isA<IndexVerificationException>()),
    );
    expect(
      () => ToolchainIndex.verifyAndParse(Uint8List.fromList(utf8.encode('nope')), {'k1': key.publicKeyBase64}, src),
      throwsA(isA<IndexVerificationException>()),
    );
  });

  test('a signed entry with a path-like id is rejected', () {
    final bad = jsonDecode(jsonEncode(body)) as Map<String, Object?>;
    ((bad['toolchains'] as List).first as Map)['id'] = '../evil';
    expect(
      () => ToolchainIndex.verifyAndParse(signIndex(bad, 'k1', key), {'k1': key.publicKeyBase64}, src),
      throwsA(isA<IndexVerificationException>()),
    );
  });

  test('canonical JSON matches Python json.dumps(sort_keys, compact)', () {
    expect(
      canonicalJsonString({
        'b': 1,
        'a': 'é',
        'c': [true, null],
      }),
      '{"a":"é","b":1,"c":[true,null]}',
    );
  });
}
