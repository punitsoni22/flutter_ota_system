// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Test-only signing helpers. The private scalars below are PUBLIC TEST VALUES used only by these
// unit tests; they are not keys of any real deployment.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_system/src/security/security.dart';
import 'package:pointycastle/export.dart';

final _curve = ECCurve_secp256r1();

class TestKey {
  TestKey(this.id, int seed) : d = BigInt.from(seed) * BigInt.parse('1000000007') + BigInt.from(12345);
  final String id;
  final BigInt d;
  String get publicB64 => base64.encode((_curve.G * d)!.getEncoded(false));

  String sign(Uint8List message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64)) // RFC 6979, no randomness
      ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, _curve)));
    final s = signer.generateSignature(message) as ECSignature;
    Uint8List fixed(BigInt v) {
      final out = Uint8List(32);
      for (var i = 31; i >= 0; i--) {
        out[i] = (v & BigInt.from(0xff)).toInt();
        v >>= 8;
      }
      return out;
    }

    return base64.encode([...fixed(s.r), ...fixed(s.s)]);
  }
}

final trusted = TestKey('test-key-1', 7);
final untrusted = TestKey('test-key-1', 99); // same id, different key (stolen id, wrong key)
final otherTrusted = TestKey('test-key-2', 11);

const appId = '7c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5';
const releaseId = '6a2a62a6-34c8-426a-9f57-4d99e02c3760';
final libapp = 'a' * 64;
final iface = 'b' * 64;

/// A toolchain record and its id (Phase 3C provenance).
Map<String, Object?> toolchainFields({String compiler = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'}) => {
      'flutter': '3.47.9', 'dart': '3.13.7', 'engine': '89c39edf', 'dart_revision': '416e33b0',
      'engine_patch_sha256': 'e' * 64, 'compiler_sha256': compiler, 'generator_sha256': 'f' * 64,
      'bytecode_format': 3, 'build_config_sha256': '1' * 64,
    };
String toolchainId(Map<String, Object?> fields) => sha256.convert(canonicalJson(fields)).toString();
Map<String, Object?> toolchain({String? compiler}) {
  final f = compiler == null ? toolchainFields() : toolchainFields(compiler: compiler);
  return {...f, 'id': toolchainId(f)};
}

HostIdentity host() => HostIdentity(
      appId: appId,
      releaseId: releaseId,
      baselineLibappSha256: libapp,
      runtime: const {'flutter': '3.47.9', 'dart': '3.13.7', 'engine': '89c39edf', 'abi': 'android-arm64', 'runtime_id': 'proto-dbc-flutter-3.47.9'},
      interfaceSha256: iface,
      hostPackages: {'app_core', 'app_models', 'shared_state', 'product_service', 'flutter', 'crypto'},
      hostOwnedPackages: {'app_core', 'app_models', 'shared_state'},
      entryContract: 2,
      toolchainId: toolchainId(toolchainFields()),
    );

Es256Verifier verifierFor(List<TestKey> keys) => Es256Verifier({for (final k in keys) k.id: k.publicB64});

final module = Uint8List.fromList(List<int>.generate(4096, (i) => (i * 31 + 7) & 0xff));

Map<String, Object?> manifest({int sequence = 5, String? patchId, Uint8List? moduleBytes, String keyId = 'test-key-1'}) {
  final mod = moduleBytes ?? module;
  return {
    'format': 2,
    'app_id': appId,
    'release_id': releaseId,
    'baseline_libapp_sha256': libapp,
    'patch_id': patchId ?? '11111111-2222-4333-8444-555555555555',
    'sequence': sequence,
    'key_id': keyId,
    'created_at': '2026-11-12T10:00:00Z',
    'runtime': {'flutter': '3.47.9', 'dart': '3.13.7', 'engine': '89c39edf', 'abi': 'android-arm64', 'runtime_id': 'proto-dbc-flutter-3.47.9'},
    'module': {'format': 'dart-bytecode', 'sha256': sha256.convert(mod).toString(), 'size': mod.length, 'entry_contract': 2},
    'packages': <Object?>[
      {'name': 'feature_catalog', 'module_name': 'feature_catalog_patch1', 'version': '1.0.0', 'source': 'internal'},
    ],
    'host_interface': {'sha256': iface, 'host_packages': <Object?>['app_core', 'app_models', 'flutter']},
    'assets': <Object?>[],
    'toolchain': toolchain(),
  };
}

Uint8List signed(Map<String, Object?> m, {TestKey? key, Uint8List? moduleBytes, String domain = manifestDomain}) {
  final k = key ?? trusted;
  final body = canonicalJson(m);
  final sig = canonicalJson({'alg': 'ES256', 'key_id': k.id, 'sig': k.sign(signedMessage(domain, body))});
  return buildContainer(body, sig, moduleBytes ?? module);
}

VerifiedPatch run(Uint8List file,
        {DeviceSecurityState? state, DateTime? now, bool reinstall = false, List<TestKey>? keys, CertificateTrust? trust}) =>
    verifyPatch(file,
        host: host(),
        keys: verifierFor(keys ?? [trusted, otherTrusted]),
        state: state ?? DeviceSecurityState(),
        now: now ?? DateTime.utc(2026, 11, 12, 12),
        reinstall: reinstall,
        trust: trust);
