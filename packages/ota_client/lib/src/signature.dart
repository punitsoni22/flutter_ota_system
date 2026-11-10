import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Verifies ES256 signatures (raw r||s, base64) against embedded public keys.
///
/// Keys are uncompressed P-256 points (0x04 || X || Y), base64-encoded, keyed by key id.
/// Print them with `ota key show --dart`.
class SignatureVerifier {
  SignatureVerifier(Map<String, String> publicKeys)
      : _keys = {
          for (final e in publicKeys.entries) e.key: _parsePoint(e.value),
        };

  final Map<String, ECPublicKey> _keys;

  static final _curve = ECCurve_secp256r1();

  static ECPublicKey _parsePoint(String base64Point) {
    final point = _curve.curve.decodePoint(base64.decode(base64Point));
    if (point == null) throw ArgumentError('Invalid public key point');
    return ECPublicKey(point, _curve);
  }

  bool knowsKey(String keyId) => _keys.containsKey(keyId);

  bool verify(String keyId, Uint8List message, String signatureBase64) {
    final key = _keys[keyId];
    if (key == null) return false;
    final Uint8List raw;
    try {
      raw = base64.decode(signatureBase64);
    } on FormatException {
      return false;
    }
    if (raw.length != 64) return false;
    final signature = ECSignature(_toBigInt(raw.sublist(0, 32)), _toBigInt(raw.sublist(32)));
    final signer = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(key));
    try {
      return signer.verifySignature(message, signature);
    } catch (_) {
      return false;
    }
  }

  static BigInt _toBigInt(List<int> bytes) =>
      bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));
}
