// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:math';

import 'package:flutter_ota_system/src/bytecode/config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  String encode(Map<String, Object?> j) => FlutterOtaConfig.encode(j);

  test('a valid config is parsed', () {
    final r = FlutterOtaConfig.parse(configDefine());
    expect(r.disabledReason, isNull);
    final c = r.config!;
    expect(c.appId, appId);
    expect(c.releaseId, releaseId);
    expect(c.entryContract, 3);
    expect(c.channel, 'production');
    expect(c.releaseVersion, isNull);
    expect(c.hostOwnedPackages, containsAll(['flutter', 'dynamic_modules', 'flutter_ota_system']));
    expect(c.certificateTrust().requireCertificates, isTrue);
  });

  test('unpadded base64url is accepted (dart-defines strip nothing, but CLIs may)', () {
    final padded = configDefine();
    expect(FlutterOtaConfig.parse(padded.replaceAll('=', '')).config, isNotNull);
  });

  test('optional fields are read; unknown fields only warn', () {
    final r = FlutterOtaConfig.parse(
      configDefine(extra: {'release_version': '2.0.0+7', 'channel': 'staging', 'future_field': 1}),
    );
    expect(r.config!.releaseVersion, '2.0.0+7');
    expect(r.config!.channel, 'staging');
    expect(r.warnings.single, contains('future_field'));
  });

  group('missing or invalid config disables OTA and never throws', () {
    final cases = <String, String>{
      'empty (plain flutter run)': '',
      'whitespace': '   ',
      'not base64': '%%%not-base64%%%',
      'not JSON': base64Url.encode(utf8.encode('hello')),
      'not canonical (spaces)': base64Url.encode(utf8.encode('{"format": 1}')),
      'a JSON list': base64Url.encode(utf8.encode('[1]')),
      'missing app_id': encode(configJson()..remove('app_id')),
      'wrong format': encode(configJson()..['format'] = 2),
      'entry contract 2': encode(configJson()..['entry_contract'] = 2),
      'bad app id': encode(configJson()..['app_id'] = 'shop-app'),
      'no root keys': encode(configJson()..['root_keys'] = <String, Object?>{}),
      'root key not a point': encode(configJson()..['root_keys'] = {'r': base64.encode(List.filled(33, 5))}),
      'server url ftp': encode(configJson()..['server_url'] = 'ftp://x'),
      'runtime missing abi': encode(configJson()..['runtime'] = ({...runtimeId}..remove('abi'))),
      'bad toolchain id': encode(configJson()..['toolchain_id'] = 'xyz'),
      'bad host package': encode(configJson()..['host_packages'] = ['Bad-Name']),
      'bad approvals': encode(configJson()..['required_approvals'] = -1),
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      test(key, () {
        final r = FlutterOtaConfig.parse(value);
        expect(r.config, isNull);
        expect(r.disabledReason, isNotEmpty);
      });
    }

    test('5000 random strings', () {
      final rng = Random(20261112);
      for (var i = 0; i < 5000; i++) {
        final s = String.fromCharCodes(List.generate(rng.nextInt(80), (_) => rng.nextInt(127) + 1));
        final r = FlutterOtaConfig.parse(rng.nextBool() ? s : base64Url.encode(utf8.encode(s)));
        expect(r.config, isNull);
      }
    });
  });

  test('host identity binds the device-computed libapp.so hash', () {
    final h = testConfig().hostIdentity('c' * 64);
    expect(h.baselineLibappSha256, 'c' * 64);
    expect(h.toolchainId, toolchainIdOf());
  });
}

String toolchainIdOf() => (jsonDecode(utf8.decode(base64Url.decode(configDefine()))) as Map)['toolchain_id'] as String;
