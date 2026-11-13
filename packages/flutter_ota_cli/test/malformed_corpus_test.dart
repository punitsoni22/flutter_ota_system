// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// tool/malformed_corpus.dart: every generated container must pass the PRODUCTION SDK's
// cryptographic verification (signature, certificate chain, module hash and size) while its
// module is exactly the malformed fixture, so only the in-VM bytecode verifier can refuse it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/src/patch/release_record.dart';
import 'package:flutter_ota_cli/src/signing/key_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The SDK's verifier is plain Dart (crypto + pointycastle, both dependencies of this package too);
// it is imported from its source so the test checks the code that runs on the device.
// ignore: avoid_relative_lib_imports
import '../../ota_client/lib/src/security/security.dart' as sdk;
import '../tool/malformed_corpus.dart';
import 'patch_support.dart';

void main() {
  late Directory tmp;
  late Map<String, String> env;
  final now = DateTime.utc(2026, 11, 13, 12);
  final fixturesDir = p.normalize(
    p.join(Directory.current.path, '..', '..', 'prototypes', 'security_hardening', 'tools', 'bc_verify', 'fixtures'),
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flutter_ota_corpus_test');
    env = {'HOME': tmp.path, 'FLUTTER_OTA_CONFIG_DIR': p.join(tmp.path, 'config')};
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('signed corpus containers verify with the SDK verifier and carry the malformed bytes', () {
    final keys = createTestKeys(env, now: now);
    final release = ReleaseRecord.load(
      writeTestRelease(tmp.path, rootKeys: keys.roots, hostPackages: {'core', 'flutter', 'shop'}),
    );
    final signer = loadLocalSigner(
      env,
      appId: release.appId,
      environment: release.environment,
      now: now,
      rootPublicKeys: release.rootKeys,
    );
    final malformed = Directory(p.join(fixturesDir, 'malformed')).listSync().whereType<File>().toList();
    expect(malformed.length, 10, reason: 'the 10 committed malformed fixtures');
    final modules = <String, Uint8List>{
      for (final f in malformed) p.basenameWithoutExtension(f.path): f.readAsBytesSync(),
      ...syntheticModules(),
    };
    final template = {
      'manifest': {
        'packages': [
          {'name': 'products', 'module_name': 'products_ota1', 'version': '1.2.0', 'source': 'internal'},
        ],
        'host_interface': {
          'host_packages': ['core', 'flutter'],
        },
      },
    };
    final corpus = buildMalformedCorpus(
      release: release,
      signer: signer,
      modules: modules,
      firstSequence: 40,
      now: now,
      template: template,
    );
    expect(corpus.map((e) => e.sequence), List.generate(12, (i) => 40 + i));
    expect(corpus.map((e) => e.patchId).toSet().length, 12);

    final host = sdk.HostIdentity(
      appId: release.appId,
      releaseId: release.releaseId,
      baselineLibappSha256: release.libappSha256,
      runtime: release.runtime,
      interfaceSha256: release.interfaceSha256,
      hostPackages: release.hostPackages,
      hostOwnedPackages: {'flutter', 'sky_engine', 'dynamic_modules', 'flutter_ota_system'},
      entryContract: 3,
      toolchainId: release.toolchainId,
    );
    final trust = sdk.CertificateTrust(roots: sdk.Es256Verifier(release.rootKeys), environment: 'production');
    sdk.VerifiedPatch verify(Uint8List f) => sdk.verifyPatch(
      f,
      host: host,
      keys: sdk.Es256Verifier(const {}),
      state: sdk.DeviceSecurityState(),
      now: now,
      trust: trust,
    );

    final recorded = (jsonDecode(File(p.join(fixturesDir, 'fixtures.json')).readAsStringSync())['files'] as Map)
        .cast<String, Object?>();
    for (final e in corpus) {
      final v = verify(e.container);
      expect(v.module, modules[e.name], reason: '${e.name}: module bytes must be the malformed bytes, unchanged');
      expect(v.manifest.patchId, e.patchId);
      expect(v.manifest.sequence, e.sequence);
      expect(v.manifest.moduleSha256, sha256.convert(modules[e.name]!).toString());
      final fixture = recorded['malformed/${e.name}.bc'] as Map?;
      if (fixture != null) expect(v.manifest.moduleSha256, fixture['fixture_sha256'], reason: e.name);
    }
    expect(corpus.map((e) => e.name), containsAll(['25_codes_opcode_1', '27_codes_opcode_3']));

    // Sanity: the SDK does check these containers (a changed module byte is refused).
    final b25 = corpus.firstWhere((e) => e.name == '25_codes_opcode_1').container;
    final tampered = Uint8List.fromList(b25)..[b25.length - 1] ^= 1;
    expect(() => verify(tampered), throwsA(isA<sdk.PatchRejected>().having((x) => x.code, 'code', 'bad_hash')));
  });
}
