// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Fixture f;
  setUp(() async => f = await Fixture.create());
  tearDown(() => f.dispose());

  const uuid = '3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f';

  group('init', () {
    test('writes exactly app_id', () async {
      expect(await f.run(['init', '--app-id', uuid.toUpperCase()]), 0);
      expect(File(p.join(f.project, 'flutter_ota.yaml')).readAsStringSync(), 'app_id: $uuid\n');
      expect(readAppId(f.project), uuid);
    });

    test('refuses slugs, package names and non-v4 UUIDs', () async {
      for (final bad in ['my-app', 'com.example.app', '3f2b8c1e-5d4a-1e7b-9c0f-1a2b3c4d5e6f', '']) {
        f.err.clear();
        expect(await f.run(['init', '--app-id', bad]), 1, reason: bad);
        expect(f.err.toString(), contains('not a valid app_id'));
      }
      expect(File(p.join(f.project, 'flutter_ota.yaml')).existsSync(), isFalse);
    });

    test('does not overwrite without --force', () async {
      expect(await f.run(['init', '--app-id', uuid]), 0);
      const other = '0b5e6c1a-4f2d-4c8e-9a71-3d2f6e8b9c01';
      expect(await f.run(['init', '--app-id', other]), 1);
      expect(readAppId(f.project), uuid);
      expect(await f.run(['init', '--app-id', other, '--force']), 0);
      expect(readAppId(f.project), other);
    });

    test('without --app-id and without a terminal it asks for the flag', () async {
      expect(await f.run(['init']), 1);
      expect(f.err.toString(), contains('--app-id'));
    });

    test('flutter_ota.yaml with extra keys is refused', () {
      File(p.join(f.project, 'flutter_ota.yaml')).writeAsStringSync('app_id: $uuid\nserver_url: https://x\n');
      expect(() => readAppId(f.project), throwsA(isA<CliException>()));
    });
  });

  group('config', () {
    test('set/get round trip, file mode 0600', () async {
      expect(await f.run(['config', 'set', 'server-url', 'https://ota.example.com/']), 0);
      f.out.clear();
      expect(await f.run(['config', 'get', 'server-url']), 0);
      expect(f.out.toString().trim(), 'https://ota.example.com');
      final path = UserConfig.pathFor(f.env());
      expect(path, p.join(f.configDir, 'config.yaml'));
      expect(FileStat.statSync(path).mode & 0x1ff, 0x180); // 0600
    });

    test('precedence: flag > environment > config file', () async {
      await f.run(['config', 'set', 'server-url', 'https://file.example.com']);
      final env = f.env({'FLUTTER_OTA_SERVER_URL': 'https://env.example.com'});
      final cfg = UserConfig.load(env);
      expect(cfg.resolve('server-url', f.env()).value, 'https://file.example.com');
      expect(cfg.resolve('server-url', f.env()).source, ConfigSource.file);
      expect(cfg.resolve('server-url', env).value, 'https://env.example.com');
      expect(cfg.resolve('server-url', env).source, ConfigSource.environment);
      expect(cfg.resolve('server-url', env, flag: 'https://flag.example.com').source, ConfigSource.flag);
      f.out.clear();
      await f.run(['config', 'get', 'server-url'], extraEnv: {'FLUTTER_OTA_SERVER_URL': 'https://env.example.com'});
      expect(f.out.toString().trim(), 'https://env.example.com');
      f.out.clear();
      await f.run(['config', 'list'], extraEnv: {'FLUTTER_OTA_SERVER_URL': 'https://env.example.com'});
      expect(f.out.toString(), contains('environment FLUTTER_OTA_SERVER_URL'));
    });

    test('XDG default path', () {
      expect(UserConfig.pathFor({'HOME': '/h'}), '/h/.config/flutter_ota/config.yaml');
      expect(UserConfig.pathFor({'HOME': '/h', 'XDG_CONFIG_HOME': '/x'}), '/x/flutter_ota/config.yaml');
    });

    test('plain http is refused except for localhost; unknown keys refused', () async {
      expect(await f.run(['config', 'set', 'server-url', 'http://ota.example.com']), 1);
      expect(await f.run(['config', 'set', 'server-url', 'http://localhost:8000']), 0);
      expect(await f.run(['config', 'set', 'api-key', 'secret']), 1);
    });

    test('add-toolchain-key accepts only valid public keys', () async {
      expect(await f.run(['config', 'add-toolchain-key', 'k', 'not-a-key']), 1);
      expect(UserConfig.load(f.env()).toolchainKeys, isEmpty);
      await f.configure();
      expect(UserConfig.load(f.env()).toolchainKeys.keys, [keyId]);
    });
  });

  test('cache root: FLUTTER_OTA_CACHE, XDG_CACHE_HOME, default', () {
    expect(CachePaths.fromEnvironment({'HOME': '/h'}).root, '/h/.cache/flutter_ota');
    expect(CachePaths.fromEnvironment({'HOME': '/h', 'XDG_CACHE_HOME': '/c'}).root, '/c/flutter_ota');
    expect(CachePaths.fromEnvironment({'HOME': '/h', 'FLUTTER_OTA_CACHE': '/o'}).root, '/o');
  });
}
