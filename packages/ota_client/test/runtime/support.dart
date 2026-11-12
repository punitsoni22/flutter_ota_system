// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Test helpers for the bytecode runtime: a build config, root-certified dbc-v1 containers,
// revocation lists, a fake native platform and a fake module loader. The private scalars come
// from ../security/support.dart: PUBLIC TEST VALUES, not keys of any real deployment.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_system/src/bytecode/config.dart';
import 'package:flutter_ota_system/src/bytecode/exit_info.dart';
import 'package:flutter_ota_system/src/bytecode/module_entry.dart';
import 'package:flutter_ota_system/src/bytecode/runtime_platform.dart';
import 'package:flutter_ota_system/src/bytecode/verifier_main.dart';
import 'package:flutter_ota_system/src/security/security.dart';

import '../security/support.dart' show TestKey, appId, releaseId, toolchain, toolchainFields, toolchainId;

export '../security/support.dart' show TestKey, appId, releaseId;

final root = TestKey('root-1', 5001);
final otherRoot = TestKey('root-x', 5003);
final signer = TestKey('signer-1', 5002);
final libappSha = 'a' * 64;
final ifaceSha = 'b' * 64;
const runtimeId = {
  'abi': 'android-arm64',
  'dart': '3.13.7',
  'engine': '89c39edf',
  'flutter': '3.47.9',
  'runtime_id': 'dbc-flutter-3.47.9',
};

Map<String, Object?> configJson({String serverUrl = 'https://ota.example.invalid', Map<String, Object?>? extra}) => {
  'format': 1,
  'app_id': appId,
  'server_url': serverUrl,
  'release_id': releaseId,
  'environment': 'production',
  'root_keys': {root.id: root.publicB64},
  'toolchain_id': toolchainId(toolchainFields()),
  'runtime': runtimeId,
  'interface_sha256': ifaceSha,
  'host_packages': ['flutter', 'flutter_ota_system', 'core'],
  'entry_contract': 3,
  ...?extra,
};

String configDefine({String serverUrl = 'https://ota.example.invalid', Map<String, Object?>? extra}) =>
    FlutterOtaConfig.encode(configJson(serverUrl: serverUrl, extra: extra));

FlutterOtaConfig testConfig() => FlutterOtaConfig.parse(configDefine()).config!;

Map<String, Object?> cert(TestKey key, {TestKey? by, int serial = 1, String env = 'production'}) {
  final issuer = by ?? root;
  final body = <String, Object?>{
    'type': 'key_cert',
    'app_id': appId,
    'environment': env,
    'key_id': key.id,
    'public_key': key.publicB64,
    'roles': ['signer'],
    'serial': serial,
    'not_before': '2026-01-01T00:00:00Z',
    'not_after': '2027-12-31T00:00:00Z',
  };
  return {'body': body, 'root_key_id': issuer.id, 'sig': issuer.sign(signedMessage(keyCertDomain, canonicalJson(body)))};
}

String patchUuid(int n) => '${n.toRadixString(16).padLeft(8, '0')}-2222-4333-8444-555555555555';

/// Module bytes for test patch [n] (the fake loader maps them to an entry result).
Uint8List moduleBytes(int n) => Uint8List.fromList(List<int>.generate(512 + n, (i) => (i * 7 + n) & 0xff));

/// A root-certified dbc-v1 container (contract 3) for patch number [n].
Uint8List dbcContainer(int n, {int? sequence, String? patchId, Uint8List? module, Map<String, Object?>? certOverride}) {
  final mod = module ?? moduleBytes(n);
  final m = <String, Object?>{
    'format': 2,
    'app_id': appId,
    'release_id': releaseId,
    'baseline_libapp_sha256': libappSha,
    'patch_id': patchId ?? patchUuid(n),
    'sequence': sequence ?? n,
    'key_id': signer.id,
    'created_at': '2026-11-12T10:00:00Z',
    'runtime': runtimeId,
    'module': {'format': 'dart-bytecode', 'sha256': sha256.convert(mod).toString(), 'size': mod.length, 'entry_contract': 3},
    'packages': <Object?>[
      {'name': 'products', 'module_name': 'products_p$n', 'version': '1.0.0', 'source': 'internal'},
    ],
    'host_interface': {'sha256': ifaceSha, 'host_packages': <Object?>['flutter', 'core']},
    'assets': <Object?>[],
    'toolchain': toolchain(),
  };
  final body = canonicalJson(m);
  final sig = canonicalJson({
    'alg': 'ES256',
    'key_id': signer.id,
    'sig': signer.sign(signedMessage(manifestDomain, body)),
    'cert': certOverride ?? cert(signer),
  });
  return buildContainer(body, sig, mod);
}

/// A revocation list signed by [by] (default: the app root).
Uint8List revocationList(int sequence, {List<String> patchIds = const [], List<String> keyIds = const [], TestKey? by}) {
  final k = by ?? root;
  final body = canonicalJson({
    'type': 'revocations',
    'release_id': releaseId,
    'sequence': sequence,
    'revoked_patch_ids': patchIds,
    'revoked_key_ids': keyIds,
  });
  final sig = canonicalJson({'alg': 'ES256', 'key_id': k.id, 'sig': k.sign(signedMessage(revocationDomain, body))});
  return buildContainer(body, sig, Uint8List(0));
}

/// Fake `dynamic_modules` loader: module bytes -> entry-point result.
class FakeModules {
  final Map<String, Object? Function()> _entries = {};
  int loads = 0;

  void add(Uint8List module, Object? Function() entry) => _entries[sha256.convert(module).toString()] = entry;

  Future<Object?> load(Uint8List bytes) async {
    loads++;
    final e = _entries[sha256.convert(bytes).toString()];
    if (e == null) throw StateError('Bytecode verification failed: unknown test module');
    return e();
  }
}

/// Fake Android side: storage in a temp dir, a scripted last exit, a separate-process verifier
/// that runs the SDK's real check ([verifyModuleBytes]) unless an outcome is forced.
class FakePlatform implements FlutterOtaPlatform {
  FakePlatform(this.filesDir);

  final Directory filesDir;
  ExitInfo? exit;
  VerifyOutcome? forcedOutcome;
  int verifyCalls = 0;
  int libappCalls = 0;

  @override
  Future<NativeStartupInfo> startupInfo() async => NativeStartupInfo(filesDir: filesDir.path, appVersion: '1.0.0+1');

  @override
  Future<ExitInfo?> lastExit() async => exit;

  @override
  Future<String> libappSha256() async {
    libappCalls++;
    return libappSha;
  }

  @override
  Future<VerifyOutcome> verifyInProcess(File moduleFile, FlutterOtaModuleLoader loader, {required Duration timeout}) async {
    verifyCalls++;
    if (forcedOutcome != null) return forcedOutcome!;
    final r = await verifyModuleBytes(moduleFile.readAsBytesSync(), loader);
    return VerifyOutcome(r['status']! as String, '${r['detail']}');
  }
}
