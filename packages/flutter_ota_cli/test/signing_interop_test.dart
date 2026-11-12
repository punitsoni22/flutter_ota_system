// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/patch/container.dart';
import 'package:flutter_ota_cli/src/patch/manifest.dart';
import 'package:flutter_ota_cli/src/patch/module_builder.dart';
import 'package:flutter_ota_cli/src/patch/pipeline.dart';
import 'package:flutter_ota_cli/src/patch/release_record.dart';
import 'package:flutter_ota_cli/src/signing/certificate.dart';
import 'package:flutter_ota_cli/src/signing/key_store.dart';
import 'package:flutter_ota_cli/src/signing/patch_signer.dart';
import 'package:flutter_ota_cli/src/toolchain/es256.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'patch_support.dart';

void main() {
  late Directory tmp;
  late Map<String, String> env;
  final now = DateTime.utc(2026, 11, 12, 12);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flutter_ota_signing_test');
    env = {'HOME': tmp.path, 'FLUTTER_OTA_CONFIG_DIR': p.join(tmp.path, 'config')};
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final module = Uint8List.fromList(List<int>.generate(3000, (i) => (i * 7 + 3) & 0xff));

  Map<String, Object?> manifestFor(ReleaseRecord r, String keyId, {int sequence = 1, String? patchId}) => buildManifest(
    release: r,
    module: module,
    built: BuiltModule(
      modulePath: '',
      renames: {'products': 'products_ota1', 'cart': 'cart_ota1'},
      hostPackages: ['core', 'flutter', 'shop'],
      guardReport: null,
      verifierOutput: 'OK',
      packageVersions: {'products': '1.2.0', 'cart': '0.3.0'},
    ),
    sequence: sequence,
    patchId: patchId ?? randomUuidV4(),
    keyId: keyId,
    now: now,
  );

  Map<String, Object?> hostJson(
    ReleaseRecord r,
    Map<String, String> roots, {
    String? releaseId,
    String environment = 'production',
  }) => {
    'app_id': r.appId,
    'release_id': releaseId ?? r.releaseId,
    'baseline_libapp_sha256': r.libappSha256,
    'runtime': r.runtime,
    'interface_sha256': r.interfaceSha256,
    'host_packages': ['core', 'flutter', 'shop', 'products', 'cart'],
    'host_owned_packages': ['core'],
    'entry_contract': 3,
    'toolchain_id': r.toolchainId,
    'roots': roots,
    'environment': environment,
    'now': now.toIso8601String(),
  };

  test('CLI-signed container verifies with patch_security verifyPatch (and its checks still bite)', () async {
    final keys = createTestKeys(env, now: now);
    final r = ReleaseRecord.load(writeTestRelease(tmp.path, rootKeys: keys.roots, hostPackages: {'core'}));
    final signer = loadLocalSigner(
      env,
      appId: testAppId,
      environment: 'production',
      now: now,
      rootPublicKeys: r.rootKeys,
    );
    final m = manifestFor(r, signer.keyId, sequence: 7);
    final otp = signPatch(m, module, signer);
    checkSignedContainer(otp, signer.certificate, r.rootKeys);
    final file = File(p.join(tmp.path, 'patch.otp'))..writeAsBytesSync(otp);

    final ok = await verifyWithPatchSecurity(hostJson(r, keys.roots), [file.path]);
    if (ok == null) {
      markTestSkipped('patch_security harness unavailable (needs the pub cache)');
      return;
    }
    expect(ok.single, 'OK ${m['patch_id']} 7');
    final otherRelease = await verifyWithPatchSecurity(
      hostJson(r, keys.roots, releaseId: '6a2a62a6-34c8-426a-9f57-4d99e02c3760'),
      [file.path],
    );
    expect(otherRelease!.single, startsWith('REJECT wrong_release'));
    final otherEnv = await verifyWithPatchSecurity(hostJson(r, keys.roots, environment: 'development'), [file.path]);
    expect(otherEnv!.single, startsWith('REJECT wrong_environment'));
    final tampered = Uint8List.fromList(otp)..[otp.length - 1] ^= 1;
    final t = File(p.join(tmp.path, 'tampered.otp'))..writeAsBytesSync(tampered);
    expect((await verifyWithPatchSecurity(hostJson(r, keys.roots), [t.path]))!.single, startsWith('REJECT bad_hash'));
  });

  test('container layout, signature block and domain separation', () {
    final keys = createTestKeys(env, now: now);
    final r = ReleaseRecord.load(writeTestRelease(tmp.path, rootKeys: keys.roots, hostPackages: {'core'}));
    final signer = loadLocalSigner(env, appId: testAppId, environment: 'production', now: now);
    final otp = signPatch(manifestFor(r, signer.keyId), module, signer);
    expect(ascii.decode(otp.sublist(0, 8)), 'OTAPRT02');
    final parts = splitContainer(otp);
    expect(parts.module, module);
    final block = jsonDecode(utf8.decode(parts.signature)) as Map<String, Object?>;
    expect(block.keys.toList(), ['alg', 'cert', 'key_id', 'sig'], reason: 'canonical: sorted keys');
    expect(block['alg'], 'ES256');
    expect(base64.decode(block['sig']! as String), hasLength(64), reason: 'raw r||s');
    final pub = parseEs256PublicKey(signer.certificate.publicKey);
    expect(es256Verify(pub, domainMessage(manifestDomain, parts.manifest), block['sig']! as String), isTrue);
    expect(es256Verify(pub, domainMessage(approvalDomain, parts.manifest), block['sig']! as String), isFalse);
    final m = jsonDecode(utf8.decode(parts.manifest)) as Map<String, Object?>;
    expect((m['module']! as Map)['entry_contract'], 3);
    expect((m['module']! as Map)['sha256'], sha256.convert(module).toString());
    expect(m['packages'], [
      {'module_name': 'cart_ota1', 'name': 'cart', 'source': 'internal', 'version': '0.3.0'},
      {'module_name': 'products_ota1', 'name': 'products', 'source': 'internal', 'version': '1.2.0'},
    ]);
    expect(m['toolchain'], testToolchainRecord());
  });

  test('manifest schema: unknown fields, assets and toolchain id are checked before signing', () {
    final keys = createTestKeys(env, now: now);
    final r = ReleaseRecord.load(writeTestRelease(tmp.path, rootKeys: keys.roots, hostPackages: {'core'}));
    final signer = loadLocalSigner(env, appId: testAppId, environment: 'production', now: now);
    Map<String, Object?> m() => manifestFor(r, signer.keyId);
    expect(() => signPatch({...m(), 'extra': 1}, module, signer), throwsA(isA<CliException>()));
    expect(
      () => signPatch(
        {
          ...m(),
          'assets': [
            {'key': 'a', 'sha256': 'a' * 64, 'size': 1},
          ],
        },
        module,
        signer,
      ),
      throwsA(isA<CliException>()),
    );
    final badTc = {...(m()['toolchain']! as Map<String, Object?>), 'compiler_sha256': 'c' * 64};
    expect(() => signPatch({...m(), 'toolchain': badTc}, module, signer), throwsA(isA<CliException>()));
    expect(() => signPatch({...m(), 'key_id': 'someone-else'}, module, signer), throwsA(isA<CliException>()));
    expect(() => validatePatchManifest(m()), returnsNormally);
  });

  test('container limits', () {
    final big = Uint8List(maxContainerBytes);
    expect(() => buildContainer(Uint8List(10), Uint8List(10), big), throwsA(isA<CliException>()));
    expect(
      () => buildContainer(Uint8List(maxManifestBytes + 1), Uint8List(10), Uint8List(1)),
      throwsA(isA<CliException>()),
    );
    expect(() => splitContainer(Uint8List.fromList(utf8.encode('OTAPRT01xxxxxxxxxxxx'))), throwsFormatException);
    final c = buildContainer(Uint8List.fromList([1]), Uint8List.fromList([2]), Uint8List.fromList([3, 4]));
    expect(c.length, 16 + 1 + 1 + 2);
  });

  group('loadLocalSigner refuses keys a device would refuse', () {
    test('no key', () {
      expect(
        () => loadLocalSigner(env, appId: testAppId, environment: 'production', now: now),
        throwsA(isA<CliException>().having((e) => e.message, 'm', contains('flutter_ota keys init'))),
      );
    });

    test('other environment', () {
      createTestKeys(env, environment: 'development', now: now);
      expect(
        () => loadLocalSigner(env, appId: testAppId, environment: 'production', now: now),
        throwsA(isA<CliException>().having((e) => e.message, 'm', contains('development'))),
      );
    });

    test('expired certificate', () {
      createTestKeys(env, now: now);
      expect(
        () =>
            loadLocalSigner(env, appId: testAppId, environment: 'production', now: now.add(const Duration(days: 400))),
        throwsA(isA<CliException>()),
      );
    });

    test('private key readable by others', () {
      final k = createTestKeys(env, now: now);
      Process.runSync('chmod', ['0644', k.signer.privateKeyPath]);
      expect(
        () => loadLocalSigner(env, appId: testAppId, environment: 'production', now: now),
        throwsA(isA<CliException>().having((e) => e.message, 'm', contains('chmod 600'))),
      );
    });

    test('certificate root not trusted by the release', () {
      createTestKeys(env, now: now);
      final other = Es256KeyPair.generate();
      expect(
        () => loadLocalSigner(
          env,
          appId: testAppId,
          environment: 'production',
          now: now,
          rootPublicKeys: {'root-other': other.publicKeyBase64},
        ),
        throwsA(isA<CliException>().having((e) => e.message, 'm', contains('which this release does not trust'))),
      );
    });
  });

  test('issueKeyCertificate matches the 4D key store format', () {
    final root = Es256KeyPair.generate();
    final kp = Es256KeyPair.generate();
    final c = issueKeyCertificate(
      root: root,
      rootKeyId: 'root-a',
      appId: testAppId,
      environment: 'production',
      keyId: 'signer-a',
      publicKey: kp.publicKeyBase64,
      roles: ['signer'],
      serial: 9,
      notBefore: now,
      notAfter: now.add(const Duration(days: 1)),
    );
    expect(KeyCertificate.parse(c.json).verifiesWith({'root-a': root.publicKeyBase64}), isTrue);
    expect(c.body['not_before'], '2026-11-12T12:00:00Z');
    expect(
      c.problemsForSigning(appId: testAppId, environment: 'production', publicKey: kp.publicKeyBase64, now: now),
      isEmpty,
    );
  });
}
