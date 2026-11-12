// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Domain prefix for toolchain index signatures. A signature over another kind of document (for
/// example a patch manifest) can never be accepted as an index signature.
const toolchainIndexDomain = 'flutter-ota-system/toolchain-index/v1\n';

final _curve = ECCurve_secp256r1();

Uint8List domainMessage(String domain, Uint8List body) => Uint8List.fromList([...utf8.encode(domain), ...body]);

/// Parses a base64 uncompressed (or compressed) P-256 point. Throws [FormatException].
ECPublicKey parseEs256PublicKey(String b64) {
  final ECPoint? point;
  try {
    point = _curve.curve.decodePoint(base64.decode(b64.trim()));
  } catch (_) {
    throw const FormatException('invalid ES256 public key');
  }
  if (point == null || point.isInfinity) throw const FormatException('invalid ES256 public key');
  return ECPublicKey(point, _curve);
}

/// Verifies an ES256 signature (raw r||s, 64 bytes, base64). Never throws.
bool es256Verify(ECPublicKey key, Uint8List message, String signatureB64) {
  final Uint8List raw;
  try {
    raw = base64.decode(signatureB64);
  } on FormatException {
    return false;
  }
  if (raw.length != 64) return false;
  final r = _toBig(raw.sublist(0, 32));
  final s = _toBig(raw.sublist(32));
  final n = _curve.n;
  if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return false;
  try {
    final signer = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(key));
    return signer.verifySignature(message, ECSignature(r, s));
  } catch (_) {
    return false;
  }
}

/// An ES256 key pair, used by the owner-side bundle tool (the CLI itself only verifies).
class Es256KeyPair {
  Es256KeyPair._(this.privateKey, this.publicKey);

  /// Generates a key with a cryptographically secure random scalar.
  factory Es256KeyPair.generate() {
    final rnd = Random.secure();
    while (true) {
      final d = _toBig(List<int>.generate(32, (_) => rnd.nextInt(256)));
      if (d > BigInt.zero && d < _curve.n) return Es256KeyPair.fromPrivateScalar(d);
    }
  }

  factory Es256KeyPair.fromPrivateScalar(BigInt d) {
    final q = (_curve.G * d)!;
    return Es256KeyPair._(ECPrivateKey(d, _curve), ECPublicKey(q, _curve));
  }

  /// Parses the private key file format written by [privateKeyBase64].
  factory Es256KeyPair.fromPrivateBase64(String b64) {
    final bytes = base64.decode(b64.trim());
    if (bytes.length != 32) throw const FormatException('private key must be 32 bytes');
    return Es256KeyPair.fromPrivateScalar(_toBig(bytes));
  }

  final ECPrivateKey privateKey;
  final ECPublicKey publicKey;

  String get privateKeyBase64 => base64.encode(_fromBig(privateKey.d!, 32));

  /// Base64 of the uncompressed point (65 bytes), the public key format used everywhere in the
  /// project.
  String get publicKeyBase64 => base64.encode(publicKey.Q!.getEncoded(false));

  /// Signs [message] (deterministic k, RFC 6979) and returns base64 raw r||s.
  String sign(Uint8List message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(privateKey));
    final sig = signer.generateSignature(message) as ECSignature;
    return base64.encode([..._fromBig(sig.r, 32), ..._fromBig(sig.s, 32)]);
  }
}

BigInt _toBig(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));

Uint8List _fromBig(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}
