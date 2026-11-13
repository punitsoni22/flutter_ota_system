// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Domain-separation prefixes: a signature over one kind of document can never be accepted as
/// another kind.
const manifestDomain = 'flutter-ota-system/patch-manifest/v2\n';
const revocationDomain = 'flutter-ota-system/revocations/v1\n';

Uint8List signedMessage(String domain, Uint8List body) => Uint8List.fromList([...utf8.encode(domain), ...body]);

/// ES256 (ECDSA P-256 + SHA-256), raw r||s, base64; public keys are base64 uncompressed points.
/// Same primitive and library as the production SDK (packages/ota_client/lib/src/signature.dart).
class Es256Verifier {
  Es256Verifier(Map<String, String> publicKeys) : _keys = {for (final e in publicKeys.entries) e.key: _parse(e.value)};

  final Map<String, ECPublicKey> _keys;
  static final _curve = ECCurve_secp256r1();

  static ECPublicKey _parse(String b64) {
    final point = _curve.curve.decodePoint(base64.decode(b64));
    if (point == null) throw ArgumentError('invalid public key');
    return ECPublicKey(point, _curve);
  }

  bool knows(String keyId) => _keys.containsKey(keyId);

  bool verify(String keyId, Uint8List message, String signatureB64) {
    final key = _keys[keyId];
    if (key == null) return false;
    final Uint8List raw;
    try {
      raw = base64.decode(signatureB64);
    } on FormatException {
      return false;
    }
    if (raw.length != 64) return false;
    BigInt big(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));
    final r = big(raw.sublist(0, 32));
    final s = big(raw.sublist(32));
    final n = _curve.n;
    if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return false;
    final signer = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(key));
    try {
      return signer.verifySignature(message, ECSignature(r, s));
    } catch (_) {
      return false;
    }
  }
}
