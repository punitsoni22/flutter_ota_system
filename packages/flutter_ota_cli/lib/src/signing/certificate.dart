// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Key certificates (Phase 3C trust chain, docs/signing-and-key-rotation.md):
//
//   app ROOT key (offline) --signs--> KEY CERTIFICATE {type, app_id, environment, key_id,
//   public_key, roles, serial, not_before, not_after} --certifies--> the developer's signer key
//   --signs--> the patch manifest.
//
// Same format and domain prefixes as prototypes/security_hardening (package:patch_security and
// tools/sign_patch.py) and the backend (backend/app/trust.py).

import 'dart:convert';

import '../errors.dart';
import '../toolchain/canonical_json.dart';
import '../toolchain/es256.dart';

const keyCertDomain = 'flutter-ota-system/key-certificate/v1\n';
const manifestDomain = 'flutter-ota-system/patch-manifest/v2\n';
const approvalDomain = 'flutter-ota-system/patch-approval/v1\n';
const revocationDomain = 'flutter-ota-system/revocations/v1\n';

final _keyIdRe = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final _isoUtc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');
const _certFields = {
  'type',
  'app_id',
  'environment',
  'key_id',
  'public_key',
  'roles',
  'serial',
  'not_before',
  'not_after',
};

bool isValidKeyId(String id) => _keyIdRe.hasMatch(id);

/// `2026-11-12T10:00:00Z` (UTC, whole seconds): the timestamp format of certificates and manifests.
String isoUtcSeconds(DateTime t) => '${t.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

/// A root-signed key certificate `{"body": {...}, "root_key_id": ..., "sig": ...}`.
class KeyCertificate {
  KeyCertificate(this.json);

  /// Parses and checks the shape (not the signature).
  factory KeyCertificate.parse(Object? json) {
    Never bad(String why) => throw CliException('Invalid key certificate: $why');
    if (json is! Map<String, Object?>) bad('not a JSON object');
    if (json.keys.toSet().difference({'body', 'root_key_id', 'sig'}).isNotEmpty) bad('unknown fields');
    final body = json['body'];
    if (body is! Map<String, Object?> || json['root_key_id'] is! String || json['sig'] is! String) bad('invalid shape');
    if (body.keys.toSet().difference(_certFields).isNotEmpty || !_certFields.every(body.containsKey)) {
      bad('body has unknown or missing fields');
    }
    if (body['type'] != 'key_cert') bad('not a key certificate');
    if (body['serial'] is! int) bad('serial is not an integer');
    if (body['roles'] is! List) bad('roles is not a list');
    for (final k in ['not_before', 'not_after']) {
      final v = body[k];
      if (v is! String || !_isoUtc.hasMatch(v)) bad('$k is not a UTC timestamp');
    }
    return KeyCertificate(json);
  }

  final Map<String, Object?> json;

  Map<String, Object?> get body => (json['body']! as Map).cast<String, Object?>();
  String get rootKeyId => json['root_key_id']! as String;
  String get signature => json['sig']! as String;
  String get appId => body['app_id']! as String;
  String get environment => body['environment']! as String;
  String get keyId => body['key_id']! as String;
  String get publicKey => body['public_key']! as String;
  int get serial => body['serial']! as int;
  List<String> get roles => (body['roles']! as List).cast<String>();
  DateTime get notBefore => DateTime.parse(body['not_before']! as String);
  DateTime get notAfter => DateTime.parse(body['not_after']! as String);

  /// Verifies the root signature with [rootPublicKeys] (key id -> base64 point).
  bool verifiesWith(Map<String, String> rootPublicKeys) {
    final rootKey = rootPublicKeys[rootKeyId];
    if (rootKey == null) return false;
    try {
      return es256Verify(parseEs256PublicKey(rootKey), domainMessage(keyCertDomain, canonicalJson(body)), signature);
    } on FormatException {
      return false;
    }
  }

  /// Checks that this certificate lets the key [publicKey] sign patches for [appId] in
  /// [environment] at [now]; when [rootPublicKeys] is given, also checks the root signature (the
  /// same roots the app was built with). Returns problems (empty = usable).
  List<String> problemsForSigning({
    required String appId,
    required String environment,
    required String publicKey,
    required DateTime now,
    Map<String, String>? rootPublicKeys,
  }) => [
    if (this.appId != appId) 'the certificate is for app ${this.appId}, not $appId',
    if (this.environment != environment)
      'the certificate is for the ${this.environment} environment, but the release is $environment',
    if (!roles.contains('signer')) 'the certificate does not have the signer role',
    if (this.publicKey != publicKey) 'the certificate is for another key (its public key differs from your signer key)',
    if (now.toUtc().isBefore(notBefore)) 'the certificate is not valid before ${body['not_before']}',
    if (!now.toUtc().isBefore(notAfter)) 'the certificate expired at ${body['not_after']}',
    if (rootPublicKeys != null && !rootPublicKeys.containsKey(rootKeyId))
      'the certificate was issued by root key $rootKeyId, which this release does not trust',
    if (rootPublicKeys != null && rootPublicKeys.containsKey(rootKeyId) && !verifiesWith(rootPublicKeys))
      'the certificate signature does not verify with root key $rootKeyId',
  ];

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(json);
}

/// Issues a key certificate with an application root key. Used by `keys` commands (4D) and
/// tests; the root key should stay offline.
KeyCertificate issueKeyCertificate({
  required Es256KeyPair root,
  required String rootKeyId,
  required String appId,
  required String environment,
  required String keyId,
  required String publicKey,
  required List<String> roles,
  required int serial,
  required DateTime notBefore,
  required DateTime notAfter,
}) {
  if (!isValidKeyId(keyId) || !isValidKeyId(rootKeyId)) throw CliException('Invalid key id.');
  final body = <String, Object?>{
    'type': 'key_cert',
    'app_id': appId,
    'environment': environment,
    'key_id': keyId,
    'public_key': publicKey,
    'roles': [...roles]..sort(),
    'serial': serial,
    'not_before': isoUtcSeconds(notBefore),
    'not_after': isoUtcSeconds(notAfter),
  };
  final sig = root.sign(domainMessage(keyCertDomain, canonicalJson(body)));
  return KeyCertificate({'body': body, 'root_key_id': rootKeyId, 'sig': sig});
}
