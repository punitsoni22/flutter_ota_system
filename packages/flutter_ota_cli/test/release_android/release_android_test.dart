// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import '../elf_fixture.dart';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/src/build_support/dynamic_interface.dart';
import 'package:flutter_ota_cli/src/build_support/ota_config.dart';
import 'package:flutter_ota_cli/src/keys/key_store.dart';
import 'package:flutter_ota_cli/src/release/android_release.dart';
import 'package:flutter_ota_cli/src/patch/manifest.dart' show toolchainRecordFields;
import 'package:flutter_ota_cli/src/patch/release_record.dart';
import 'package:flutter_ota_cli/src/release/ota_entry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'release_support.dart';

void main() {
  late ReleaseWorld w;
  setUp(() async => w = await ReleaseWorld.create());
  tearDown(() => w.dispose());

  Future<void> keysInit() async {
    expect(await w.run(['keys', 'init']), 0, reason: w.output);
    w.out.clear();
    w.err.clear();
  }

  String releaseDirOf(String id) => p.join(w.project, '.flutter_ota', 'releases', id);
  List<String> releaseDirs() {
    final d = Directory(p.join(w.project, '.flutter_ota', 'releases'));
    return d.existsSync() ? d.listSync().map((e) => p.basename(e.path)).toList() : [];
  }

  group('release android (fake toolchain, fake flutter, fake backend)', () {
    test('builds, writes the baseline and registers the release', () async {
      await keysInit();
      final code = await w.run(['release', 'android', '--kind', 'apk', '--', '--dart-define=MY_FLAG=on']);
      expect(code, 0, reason: w.output);

      // Exactly one release folder with the baseline files.
      final ids = releaseDirs();
      expect(ids, hasLength(1));
      final id = ids.single;
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      final rd = releaseDirOf(id);
      final store0 = AppKeyStore.forApp(w.env(), appId);
      for (final f in [
        releaseJsonName,
        linkDillName,
        dynamicInterfaceName,
        hostPackagesName,
        linkPackageConfigName,
        baselineLibappName,
        pubspecLockCopyName,
      ]) {
        expect(File(p.join(rd, f)).existsSync(), isTrue, reason: f);
      }
      final record = jsonDecode(File(p.join(rd, releaseJsonName)).readAsStringSync()) as Map<String, Object?>;
      expect(
        File(p.join(w.project, '.flutter_ota', releaseJsonName)).readAsStringSync(),
        File(p.join(rd, releaseJsonName)).readAsStringSync(),
      );

      // release.json: baseline identity.
      final libappSha = sha256.convert(w.libappBytes).toString();
      expect(record['app_id'], appId);
      expect(record['release_id'], id);
      expect(record['version'], '1.2.0+7');
      expect(record['libapp_sha256'], libappSha);
      expect(record['libflutter_sha256'], sha256.convert(w.engineBytes).toString());
      expect(record['abi'], 'android-arm64');
      expect(record['toolchain'], toolchainName);
      expect(record['toolchain_id'], w.toolchainId);
      expect(record['dart_revision'], '416e33b0');
      expect(record['bytecode_format'], 3);
      expect(record['engine'], engineCommit);
      expect(record['environment'], 'production');
      final ifaceText = File(p.join(rd, dynamicInterfaceName)).readAsStringSync();
      expect(record['interface_sha256'], sha256.convert(utf8.encode(ifaceText)).toString());
      expect(record['link_dill_sha256'], sha256.convert(File(p.join(rd, linkDillName)).readAsBytesSync()).toString());
      expect(record['host_packages'], [
        'collection',
        'demo_app',
        'dynamic_modules',
        'feature_a',
        'flutter',
        'flutter_ota_system',
        'sky_engine',
      ]);
      expect(record['registered'], isA<Map<String, Object?>>());
      final hp = jsonDecode(File(p.join(rd, hostPackagesName)).readAsStringSync()) as Map;
      expect(hp['internal'], ['demo_app', 'feature_a']);
      expect(hp['all'], isNot(contains('flutter_test')), reason: 'dev dependencies are not host packages');
      expect(File(p.join(rd, baselineLibappName)).readAsBytesSync(), w.libappBytes);

      // The interface: kernel libraries, never dart:_internal or dart:ffi.
      expect(ifaceText, contains("  - library: 'package:feature_a/feature_a.dart'"));
      expect(ifaceText, contains("  - library: 'dart:core'"));
      expect(ifaceText, isNot(contains('dart:_internal')));
      expect(ifaceText, isNot(contains('dart:ffi')));
      expect(ifaceText, isNot(contains('package:dynamic_modules/')), reason: 'a patch must not load modules');
      expect(ifaceText, isNot(contains('flutter_ota_main.g.dart')));
      expect(ifaceText, contains("'package:demo_app/main.dart'"));

      // The module loader: dynamic_modules copied from the toolchain, pubspec dependency added,
      // entry point generated exactly; the developer's main.dart unchanged.
      expect(
        File(
          p.join(w.project, '.flutter_ota', 'packages', 'dynamic_modules', 'lib', 'dynamic_modules.dart'),
        ).readAsStringSync(),
        loaderSource,
      );
      expect(record['loader_package_sha256'], sha256.convert(utf8.encode(loaderSource)).toString());
      expect(
        File(p.join(w.project, 'pubspec.yaml')).readAsStringSync(),
        contains('  dynamic_modules:\n    path: .flutter_ota/packages/dynamic_modules\n'),
      );
      expect(
        File(p.join(w.project, 'lib', 'flutter_ota_main.g.dart')).readAsStringSync(),
        renderOtaMain(mainTakesArgs: false),
      );
      expect(
        File(p.join(w.project, 'lib', 'main.dart')).readAsStringSync(),
        contains('await FlutterOta.initialize();'),
      );
      expect(File(p.join(w.project, 'lib', 'main.dart')).readAsStringSync(), isNot(contains('registerModuleLoader')));
      expect(File(p.join(rd, 'feature_snapshot.json')).existsSync(), isTrue, reason: '4F snapshot recorded');
      expect(record['entry_target'], 'lib/flutter_ota_main.g.dart');

      // The patch pipeline (4E) can read this baseline.
      for (final k in [
        'app_id',
        'release_id',
        'environment',
        'libapp_sha256',
        'toolchain_id',
        'toolchain_record',
        'runtime',
        'interface_sha256',
        'root_keys',
        'entry_contract',
        'canonical_build_root',
        'registered',
        'link_dill_sha256',
        'arch',
        'created_at',
      ]) {
        expect(record[k], isNotNull, reason: k);
      }
      expect((record['toolchain_record'] as Map).keys.toSet(), toolchainRecordFields);
      final rr = ReleaseRecord.load(rd);
      expect(rr.releaseId, id);
      expect(rr.toolchainId, w.toolchainId);
      expect(rr.manifestToolchain['id'], w.toolchainId);
      expect(rr.rootKeys, store0.rootPublicKeys());
      expect(rr.registered, isNotNull);
      expect(rr.hostPackages, contains('feature_a'));
      expect(ReleaseRecord.find(w.project).releaseId, id);

      // No user-specific path in the canonical package config.
      final linkCfg = File(p.join(rd, linkPackageConfigName)).readAsStringSync();
      expect(linkCfg.replaceAll(w.canonRoot, '<canon>'), isNot(contains(w.dir)));
      for (final pkg in (jsonDecode(linkCfg)['packages'] as List).cast<Map>()) {
        expect(pkg['rootUri'] as String, startsWith('file://${w.canonRoot}/'));
      }

      // flutter: pub get + build with the exact arguments and the toolchain environment.
      final calls = w.flutterCalls().map(ReleaseWorld.parseArgs).toList();
      expect(calls.map((c) => c.take(2).join(' ')), ['pub get', 'pub get', 'build apk']);
      final build = calls[2];

      // Build copy: pub get in the real project (generated files, IDE), then pub get and the store
      // build in the neutral copy <root>/project/<app>; the copy is removed afterwards and only
      // the APK comes back to the real project's usual output folder.
      final copyApp = p.join(w.canonRoot, 'project', 'demo_app');
      final pwds = File(w.flutterLog).readAsLinesSync().where((l) => l.startsWith('PWD ')).toList();
      expect(pwds, ['PWD ${w.project}', 'PWD $copyApp', 'PWD $copyApp']);
      expect(record['build_dir'], copyApp);
      expect(Directory(p.join(w.canonRoot, 'project')).existsSync(), isFalse, reason: 'build copy removed');
      expect(Link(p.join(w.canonRoot, 'workspace')).existsSync(), isTrue);
      expect(
        File(p.join(w.project, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')).readAsBytesSync(),
        File(p.join(w.dir, 'fake.apk')).readAsBytesSync(),
      );
      expect((record['artifact'] as Map)['path'], 'build/app/outputs/flutter-apk/app-release.apk');
      // The generated files are in the real project (checked above) and were in the copy too.
      final built = File(w.flutterLog).readAsLinesSync().where((l) => l.startsWith('BUILT-WITH ')).toSet();
      expect(built, {
        'BUILT-WITH lib/flutter_ota_main.g.dart',
        'BUILT-WITH loader package',
        'BUILT-WITH dynamic_modules dependency',
        'BUILT-WITH $dynamicInterfaceName',
        'BUILT-WITH $linkPackageConfigName',
      });
      final define = build.firstWhere((a) => a.startsWith('--dart-define=FLUTTER_OTA_CONFIG='));
      final ifaceCanon = '${w.canonRoot}/workspace/demo_app/.flutter_ota/releases/$id/dynamic_interface.yaml';
      expect(build, [
        'build',
        'apk',
        '--release',
        '-t',
        'lib/flutter_ota_main.g.dart',
        '--target-platform',
        'android-arm64',
        define,
        '--extra-front-end-options=--dynamic-interface=$ifaceCanon',
        '--build-name=1.2.0',
        '--build-number=7',
        '--dart-define=MY_FLAG=on',
      ]);
      expect(record['build_args'], build);
      final log = File(w.flutterLog).readAsStringSync();
      expect(log, contains('ENV FLUTTER_STORAGE_BASE_URL=file://${w.toolchainDir}/mirror'));
      expect(log, contains('ENV GRADLE_USER_HOME=${w.toolchainDir}/gradle-home'));
      expect(log, contains('ENV FLUTTER_ROOT=<unset>'));
      expect(log, contains('ENV PATH=${w.toolchainDir}/flutter/bin:'));
      expect(File(w.globalMarker).existsSync(), isFalse, reason: 'the global flutter must never run');

      // The single define: decode it.
      final config = decodeOtaConfig(define.substring('--dart-define=FLUTTER_OTA_CONFIG='.length));
      final store = AppKeyStore.forApp(w.env(), appId);
      expect(config, {
        'format': 1,
        'app_id': appId,
        'server_url': w.backend.url,
        'release_id': id,
        'environment': 'production',
        'root_keys': store.rootPublicKeys(),
        'toolchain_id': w.toolchainId,
        'runtime': {
          'abi': 'android-arm64',
          'dart': '3.13.7',
          'engine': '89c39edf',
          'flutter': '3.47.9',
          'runtime_id': 'dbc-$toolchainName',
        },
        'interface_sha256': record['interface_sha256'],
        'host_packages': record['host_packages'],
        'entry_contract': 3,
        'release_version': '1.2.0+7',
      });
      expect(jsonEncode(config), isNot(contains('PRIVATE')));
      for (final k in Directory(
        store.dir,
      ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.key'))) {
        expect(define, isNot(contains(k.readAsStringSync().trim())));
        expect(File(w.flutterLog).readAsStringSync(), isNot(contains(k.readAsStringSync().trim())));
      }

      // Front end: interface pass (no interface, user defines) then link.dill (same defines as the build).
      final fe = w.frontendCalls().map(ReleaseWorld.parseArgs).toList();
      expect(fe, hasLength(2));
      for (final c in fe) {
        expect(c, containsAll(['--target', 'flutter', '--no-aot', '--no-tfa', '--no-link-platform']));
        expect(c.last, 'package:demo_app/flutter_ota_main.g.dart');
        expect(
          c[c.indexOf('--packages') + 1],
          '${w.canonRoot}/workspace/demo_app/.flutter_ota/releases/$id/link_package_config.json',
        );
        expect(c[c.indexOf('--sdk-root') + 1], startsWith('${w.canonRoot}/toolchain/flutter/'));
      }
      expect(fe[0], isNot(contains('--dynamic-interface')));
      expect(fe[0], contains('-DMY_FLAG=on'));
      expect(fe[1][fe[1].indexOf('--dynamic-interface') + 1], ifaceCanon);
      expect(fe[1], containsAll(['-D${define.substring('--dart-define='.length)}', '-DMY_FLAG=on']));
      expect(record['link_defines'], [define.substring('--dart-define='.length), 'MY_FLAG=on']);

      // Backend: release with id + baseline identity, then libapp.so for arm64-v8a. No APK upload.
      final posts = w.backend.requests.where((r) => r.method == 'POST').toList();
      expect(posts.map((r) => r.path).toList(), [
        '/v1/admin/apps/$appId/trust/roots',
        '/v1/admin/apps/$appId/trust/certificates',
        '/v1/admin/apps/$appSlug/releases',
        '/v1/admin/releases/$id/artifacts',
      ]);
      for (final r in w.backend.requests.where((r) => r.path.startsWith('/v1/'))) {
        expect(r.headers.value('x-api-key'), adminKey);
      }
      final body = posts[2].json as Map<String, Object?>;
      expect(body['id'], id);
      expect(body['platform'], 'android');
      expect(body['version'], '1.2.0+7');
      expect(body['toolchain_id'], w.toolchainId);
      expect(body['dart_revision'], '416e33b0');
      expect(body['bytecode_format'], 3);
      expect(body['interface_sha256'], record['interface_sha256']);
      expect(body['trust_environment'], 'production');
      expect(w.backend.releases.single['artifacts'], [
        {'arch': 'arm64-v8a', 'sha256': libappSha, 'size_bytes': w.libappBytes.length},
      ]);
      expect(posts[3].body.length, lessThan(2000), reason: 'only libapp.so is uploaded');
      expect(w.out.toString(), contains('build/app/outputs/flutter-apk/app-release.apk'));
    });

    test('aab: reads base/lib/... from the bundle', () async {
      await keysInit();
      expect(await w.run(['release', 'android']), 0, reason: w.output);
      final build = ReleaseWorld.parseArgs(w.flutterCalls().last);
      expect(build.take(2), ['build', 'appbundle']);
      final record = jsonDecode(File(p.join(w.project, '.flutter_ota', releaseJsonName)).readAsStringSync()) as Map;
      expect((record['artifact'] as Map)['kind'], 'aab');
      expect(record['libapp_sha256'], sha256.convert(w.libappBytes).toString());
    });

    test('--build-name / --build-number override pubspec', () async {
      await keysInit();
      expect(
        await w.run(['release', 'android', '--kind', 'apk', '--build-name', '2.0.0', '--build-number', '42']),
        0,
        reason: w.output,
      );
      final build = ReleaseWorld.parseArgs(w.flutterCalls().last);
      expect(build, containsAll(['--build-name=2.0.0', '--build-number=42']));
      expect(w.backend.releases.single['version'], '2.0.0+42');
    });

    test('a stock engine in the APK is refused and nothing is registered', () async {
      await keysInit();
      w.setApk(fakeElf(stockEngineBuildId));
      expect(await w.run(['release', 'android', '--kind', 'apk']), 1);
      expect(w.err.toString(), contains('does NOT contain the OTA engine'));
      expect(w.err.toString(), contains('Do NOT upload'));
      expect(w.backend.releases, isEmpty);
      expect(releaseDirs(), isEmpty);
    });

    for (final kind in ['aab', 'apk']) {
      test('$kind: plugin libraries for other ABIs are refused and nothing is registered', () async {
        await keysInit();
        w.setApk(w.engineBytes, extraLibs: {
          'lib/arm64-v8a/libdartjni.so': [1],
          'lib/x86_64/libdartjni.so': [2],
          'lib/armeabi-v7a/libdartjni.so': [3],
        });
        expect(await w.run(['release', 'android', '--kind', kind]), 1);
        expect(w.err.toString(), contains('native libraries for armeabi-v7a, x86_64'));
        expect(w.err.toString(), contains('abiFilters += "arm64-v8a"'));
        expect(w.backend.releases, isEmpty);
        expect(releaseDirs(), isEmpty);
      });
    }

    test('extra arm64-v8a plugin libraries are fine', () async {
      await keysInit();
      w.setApk(w.engineBytes, extraLibs: {'lib/arm64-v8a/libdartjni.so': [1]});
      expect(await w.run(['release', 'android']), 0, reason: w.output);
      expect(w.backend.releases, hasLength(1));
    });

    test('a failing flutter build leaves no baseline and registers nothing', () async {
      await keysInit();
      expect(await w.run(['release', 'android', '--kind', 'apk'], extraEnv: {'FAKE_BUILD_FAIL': '1'}), 1);
      expect(w.err.toString(), contains('flutter build failed'));
      expect(w.err.toString(), contains('gradle exploded'));
      expect(w.backend.releases, isEmpty);
      expect(releaseDirs(), isEmpty);
    });

    test('version already on the server is refused before building', () async {
      await keysInit();
      w.backend.releases.add({'id': 'x', 'platform': 'android', 'version': '1.2.0+7', 'artifacts': []});
      expect(await w.run(['release', 'android', '--kind', 'apk']), 1);
      expect(w.err.toString(), contains('already has an Android release 1.2.0+7'));
      expect(w.flutterCalls(), isEmpty);
    });
  });

  group('refusals', () {
    test('no flutter_ota.yaml', () async {
      File(p.join(w.project, 'flutter_ota.yaml')).deleteSync();
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('flutter_ota init --app-id'));
      expect(w.flutterCalls(), isEmpty);
    });

    test('flutter_ota.yaml with more than app_id', () async {
      File(p.join(w.project, 'flutter_ota.yaml')).writeAsStringSync('app_id: $appId\nserver_url: https://x\n');
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('must contain only app_id'));
    });

    test('app_id that is not a UUID', () async {
      File(p.join(w.project, 'flutter_ota.yaml')).writeAsStringSync('app_id: demo-app\n');
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('looks like an app slug'));
    });

    test('missing server URL', () async {
      expect(await w.run(['release', 'android'], drop: {'FLUTTER_OTA_SERVER_URL'}), 1);
      expect(w.err.toString(), contains('flutter_ota config set server-url'));
      expect(w.flutterCalls(), isEmpty);
    });

    test('missing admin key', () async {
      expect(await w.run(['release', 'android'], drop: {'FLUTTER_OTA_ADMIN_KEY'}), 1);
      expect(w.err.toString(), contains('FLUTTER_OTA_ADMIN_KEY'));
      expect(w.err.toString(), contains('never saves it'));
      expect(w.flutterCalls(), isEmpty);
    });

    test('wrong admin key', () async {
      expect(await w.run(['release', 'android'], extraEnv: {'FLUTTER_OTA_ADMIN_KEY': 'nope'}), 1);
      expect(w.err.toString(), contains('HTTP 401'));
    });

    test('app unknown to the server', () async {
      w.backend.apps.clear();
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('has no application with id $appId'));
    });

    test('no root key yet: guides to keys init', () async {
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('flutter_ota keys init'));
      expect(w.flutterCalls(), isEmpty);
    });

    test('server root with a different public key stops the release', () async {
      await keysInit();
      w.backend.roots.single['public_key'] = 'BADKEY';
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('DIFFERENT public key'));
    });

    test('toolchain that fails verification: no build, no fallback', () async {
      await keysInit();
      File(p.join(w.toolchainDir, 'flutter', 'bin', 'flutter')).writeAsStringSync('#!/bin/sh\necho tampered\n');
      expect(await w.run(['release', 'android', '--kind', 'apk']), 1);
      expect(w.err.toString(), contains('failed verification'));
      expect(w.err.toString(), contains('never falls back'));
      expect(File(w.flutterLog).existsSync(), isFalse);
      expect(File(w.globalMarker).existsSync(), isFalse);
    });

    test('no lock file', () async {
      await keysInit();
      File(p.join(w.project, 'flutter_ota.lock')).deleteSync();
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('flutter_ota toolchain install'));
    });

    test('FLUTTER_OTA_TOOLCHAIN_DIR: used when valid, still verified', () async {
      await keysInit();
      final moved = p.join(w.dir, 'elsewhere', toolchainName);
      Directory(p.dirname(moved)).createSync();
      Directory(w.toolchainDir).renameSync(moved);
      // pub get of the moved toolchain resolves flutter and sky_engine there.
      final cfg = File(p.join(w.dir, 'package_config.json'));
      cfg.writeAsStringSync(cfg.readAsStringSync().replaceAll(w.toolchainDir, moved));
      expect(
        await w.run(['release', 'android', '--kind', 'apk'], extraEnv: {'FLUTTER_OTA_TOOLCHAIN_DIR': moved}),
        0,
        reason: w.output,
      );
      expect(File(w.flutterLog).readAsStringSync(), contains('ENV GRADLE_USER_HOME=$moved/gradle-home'));
      // Tampered: refused.
      w.err.clear();
      File(p.join(moved, 'toolchain.json')).writeAsStringSync('{}');
      w.backend.releases.clear();
      expect(await w.run(['release', 'android', '--kind', 'apk'], extraEnv: {'FLUTTER_OTA_TOOLCHAIN_DIR': moved}), 1);
      expect(w.err.toString(), contains('failed verification'));
    });

    test('pubspec without flutter_ota_system', () async {
      final f = File(p.join(w.project, 'pubspec.yaml'));
      f.writeAsStringSync(f.readAsStringSync().replaceAll('  flutter_ota_system: ^0.1.0-alpha.1\n', ''));
      expect(await w.run(['release', 'android']), 1);
      expect(w.err.toString(), contains('does not depend on flutter_ota_system'));
    });

    test('forbidden extra flutter arguments', () async {
      for (final bad in [
        ['--target-platform', 'android-arm'],
        ['--dart-define=FLUTTER_OTA_CONFIG=x'],
        ['--obfuscate'],
        ['--debug'],
        ['--dart-define=A=1,2'],
      ]) {
        w.err.clear();
        expect(await w.run(['release', 'android', '--', ...bad]), 1, reason: '$bad');
      }
      expect(w.flutterCalls(), isEmpty);
    });
  });

  group('nonArm64Abis', () {
    test('lists other ABI folders of an APK or AAB, sorted and once each', () {
      expect(nonArm64Abis(['lib/arm64-v8a/libflutter.so', 'lib/x86_64/a.so', 'lib/x86_64/b.so', 'lib/x86/c.so'], ''),
          ['x86', 'x86_64']);
      expect(nonArm64Abis(['base/lib/arm64-v8a/libapp.so', 'base/lib/armeabi-v7a/libx.so'], 'base/'), ['armeabi-v7a']);
    });

    test('ignores arm64-v8a, other modules, non-library files and files directly under lib/', () {
      expect(
        nonArm64Abis([
          'base/lib/arm64-v8a/libflutter.so',
          'feature/lib/x86_64/libx.so', // another module: not the base prefix
          'base/lib/x86_64/readme.txt',
          'base/lib/odd.so',
          'base/assets/lib/x86_64/fake.so',
        ], 'base/'),
        isEmpty,
      );
    });
  });

  group('dynamic interface', () {
    test('deterministic: same libraries in any order give identical bytes', () {
      final a = buildDynamicInterface(fakeKernelLibraries);
      final b = buildDynamicInterface(fakeKernelLibraries.reversed);
      expect(a.yaml, b.yaml);
      expect(a.sha256Hex, b.sha256Hex);
      expect(a.libraries, [
        'dart:async',
        'dart:core',
        'dart:ui',
        'package:collection/collection.dart',
        'package:demo_app/flutter_ota_main.g.dart',
        'package:demo_app/main.dart',
        'package:feature_a/feature_a.dart',
        'package:flutter/src/widgets/framework.dart',
        'package:flutter/widgets.dart',
        'package:flutter_ota_system/flutter_ota_system.dart',
      ]);
      for (final s in ['callable:', 'can-be-used-as-type:', 'extendable:', 'can-be-overridden:']) {
        expect(a.yaml, contains('\n$s\n'));
      }
      expect(a.yaml, isNot(contains('dynamically-callable')));
    });

    test('two releases of the same app produce the same interface', () async {
      await keysInit();
      expect(await w.run(['release', 'android', '--kind', 'apk']), 0, reason: w.output);
      expect(await w.run(['release', 'android', '--kind', 'apk', '--build-number', '8']), 0, reason: w.output);
      final shas = releaseDirs()
          .map(
            (id) =>
                (jsonDecode(File(p.join(releaseDirOf(id), releaseJsonName)).readAsStringSync())
                    as Map)['interface_sha256'],
          )
          .toSet();
      expect(shas, hasLength(1));
    });
  });

  group('module loader entry point', () {
    test('exact text; args passed through when main takes them', () {
      expect(renderOtaMain(mainTakesArgs: false), '''
// GENERATED by flutter_ota. Do not edit.
import 'dart:typed_data';

import 'package:dynamic_modules/dynamic_modules.dart' as dm;
import 'package:flutter_ota_system/flutter_ota_system.dart';

import 'main.dart' as app;

/// Found by name in the verifier process: keep the pragma.
@pragma('vm:entry-point')
Future<Object?> flutterOtaLoadModule(Uint8List bytes) => dm.loadModuleFromBytes(bytes);

void main() {
  FlutterOta.registerModuleLoader(flutterOtaLoadModule);
  app.main();
}
''');
      final withArgs = renderOtaMain(mainTakesArgs: true);
      expect(withArgs, contains('void main(List<String> args) {'));
      expect(withArgs, contains('  app.main(args);'));
      expect(mainDeclaresArgs('Future<void> main() async {}'), isFalse);
      expect(mainDeclaresArgs('void main(List<String> args) {}'), isTrue);
      expect(mainDeclaresArgs('// void main(List<String> a)\nvoid main() {}'), isFalse);
    });

    test('release with a main(List<String> args) and --channel', () async {
      await keysInit();
      File(p.join(w.project, 'lib', 'main.dart')).writeAsStringSync('''
import 'package:flutter_ota_system/flutter_ota_system.dart';
Future<void> main(List<String> args) async { await FlutterOta.initialize(); }
''');
      expect(await w.run(['release', 'android', '--kind', 'apk', '--channel', 'beta']), 0, reason: w.output);
      expect(
        File(p.join(w.project, 'lib', 'flutter_ota_main.g.dart')).readAsStringSync(),
        renderOtaMain(mainTakesArgs: true),
      );
      final build = ReleaseWorld.parseArgs(w.flutterCalls().last);
      final config = decodeOtaConfig(
        build.firstWhere((a) => a.startsWith('--dart-define=FLUTTER_OTA_CONFIG=')).split('=').skip(2).join('='),
      );
      expect(config['channel'], 'beta');
      expect(config['release_version'], '1.2.0+7');
    });

    test('a conflicting dynamic_modules dependency is refused', () async {
      await keysInit();
      final f = File(p.join(w.project, 'pubspec.yaml'));
      f.writeAsStringSync(
        f.readAsStringSync().replaceFirst('dependencies:\n', 'dependencies:\n  dynamic_modules: ^1.0.0\n'),
      );
      expect(await w.run(['release', 'android', '--kind', 'apk']), 1);
      expect(w.err.toString(), contains('already declares dynamic_modules differently'));
    });

    test('an old toolchain without dynamic_modules needs the escape hatch', () async {
      await keysInit();
      // Simulate an overlay from before 4D: no packages/dynamic_modules (and not in install.json).
      final rec = File(p.join(w.toolchainDir, 'install.json'));
      final j = jsonDecode(rec.readAsStringSync()) as Map<String, Object?>;
      (j['files'] as Map).removeWhere((k, _) => (k as String).startsWith('packages/'));
      rec.writeAsStringSync(jsonEncode(j));
      final copy = p.join(w.dir, 'loader-copy');
      Directory(p.join(w.toolchainDir, 'packages', 'dynamic_modules')).renameSync(copy);
      expect(await w.run(['release', 'android', '--kind', 'apk']), 1);
      expect(w.err.toString(), contains('FLUTTER_OTA_DYNAMIC_MODULES_DIR'));
      expect(
        await w.run(['release', 'android', '--kind', 'apk'], extraEnv: {'FLUTTER_OTA_DYNAMIC_MODULES_DIR': copy}),
        0,
        reason: w.output,
      );
    });
  });

  test('validateExtraArgs returns the user defines', () {
    expect(validateExtraArgs(['--dart-define=A=1', '--dart-define', 'B=2', '--flavor', 'prod']), ['A=1', 'B=2']);
  });
}
