// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/build_support/canonical_paths.dart';
import 'package:flutter_ota_cli/src/build_support/kernel_libraries.dart';
import 'package:flutter_ota_cli/src/build_support/ota_config.dart';
import 'package:flutter_ota_cli/src/build_support/zip_reader.dart';
import 'package:flutter_ota_cli/src/toolchain/canonical_json.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../release_android/release_support.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('flutter_ota_build_support').absolute);
  tearDown(() => tmp.deleteSync(recursive: true));

  group('kernel library reader', () {
    test('lists stored libraries, sorted; ignores names that are only referenced', () {
      final k = makeKernel(['package:b/b.dart', 'dart:core', 'package:a/a.dart'], extraReferencedOnly: 3);
      expect(kernelLibraryUris(k), ['dart:core', 'package:a/a.dart', 'package:b/b.dart']);
    });

    test('long names and many libraries (multi-byte UInt encoding)', () {
      final libs = [for (var i = 0; i < 300; i++) 'package:p$i/${'x' * 200}.dart'];
      expect(kernelLibraryUris(makeKernel(libs)), libs.toList()..sort());
    });

    test('concatenated components', () {
      final a = makeKernel(['package:a/a.dart']);
      final b = makeKernel(['package:b/b.dart']);
      expect(kernelLibraryUris(Uint8List.fromList([...a, ...b])), ['package:a/a.dart', 'package:b/b.dart']);
    });

    test('rejects other files', () {
      final k = makeKernel(['dart:core']);
      k[0] = 0;
      expect(() => kernelLibraryUris(k), throwsFormatException);
      expect(() => kernelLibraryUris(Uint8List.fromList(utf8.encode('hello'))), throwsFormatException);
      expect(() => kernelLibraryUris(Uint8List(64)), throwsFormatException);
    });

    // Optional check against a real link.dill (set FLUTTER_OTA_TEST_LINK_DILL to its path).
    final real = Platform.environment['FLUTTER_OTA_TEST_LINK_DILL'];
    test('real link.dill', () {
      final libs = kernelLibraryUrisOfFile(real!);
      expect(libs, contains('dart:core'));
      expect(libs.where((l) => l.startsWith('package:flutter/')), isNotEmpty);
    }, skip: real == null ? 'FLUTTER_OTA_TEST_LINK_DILL not set' : false);
  });

  group('zip reader', () {
    test('stored and deflated entries', () {
      final data = List<int>.generate(100000, (i) => i % 251);
      for (final deflate in [false, true]) {
        final f = File(p.join(tmp.path, 'a$deflate.zip'))
          ..writeAsBytesSync(makeZip({'lib/x.so': data, 'b.txt': utf8.encode('hi')}, deflate: deflate));
        expect(readZipEntry(f.path, 'lib/x.so'), data);
        expect(utf8.decode(readZipEntry(f.path, 'b.txt')!), 'hi');
        expect(readZipEntry(f.path, 'missing'), isNull);
      }
    });

    test('not a zip', () {
      final f = File(p.join(tmp.path, 'x'))..writeAsStringSync('nope');
      expect(() => readZipEntry(f.path, 'a'), throwsFormatException);
    });
  });

  group('FLUTTER_OTA_CONFIG', () {
    test('canonical, base64url, no commas, round trip', () {
      final cfg = buildOtaConfig(
        appId: appId,
        serverUrl: 'https://ota.example.com',
        releaseId: '0b5e6c1a-4f2d-4c8e-9a71-3d2f6e8b9c01',
        environment: 'production',
        rootKeys: {'root-b': 'B', 'root-a': 'A'},
        toolchainId: 'f' * 64,
        runtime: {
          'abi': 'android-arm64',
          'dart': '3.13.7',
          'engine': '89c39edf',
          'flutter': '3.47.9',
          'runtime_id': 'r',
        },
        interfaceSha256: 'e' * 64,
        hostPackages: ['a', 'b'],
      );
      final v = encodeOtaConfig(cfg);
      expect(v, isNot(contains(',')));
      expect(v, matches(RegExp(r'^[A-Za-z0-9_\-]+=*$')));
      expect(utf8.decode(base64Url.decode(v)), canonicalJsonString(cfg));
      expect(decodeOtaConfig(v), cfg);
      expect(decodeOtaConfig(v.replaceAll('=', '')), cfg);
      expect(encodeOtaConfig(Map.fromEntries(cfg.entries.toList().reversed)), v);
    });
  });

  group('canonical paths', () {
    test('mapping uses the longest prefix', () {
      final m = PathMapping({'/a': '/c/ws', '/a/b/tc': '/c/tc'});
      expect(m.map('/a/b/tc/flutter/x'), '/c/tc/flutter/x');
      expect(m.map('/a/app'), '/c/ws/app');
      expect(m.map('/a'), '/c/ws');
      expect(m.map('/elsewhere'), isNull);
    });

    test('common ancestor', () {
      expect(commonAncestor(['/w/app', '/w/packages/a']), '/w');
      expect(commonAncestor(['/w/app']), '/w/app');
      expect(commonAncestor(['/x/a', '/y/b']), '/');
    });

    test('canonical package config refuses packages outside the mapped folders', () {
      final cfgFile = File(p.join(tmp.path, 'app', '.dart_tool', 'package_config.json'))
        ..parent.createSync(recursive: true);
      Directory(p.join(tmp.path, 'outside', 'pkg')).createSync(recursive: true);
      cfgFile.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'o', 'rootUri': 'file://${tmp.path}/outside/pkg', 'packageUri': 'lib/'},
          ],
        }),
      );
      final pkgs = readPackageConfig(cfgFile.path);
      final real = tmp.resolveSymbolicLinksSync();
      expect(pkgs.first.root, p.join(real, 'app'));
      final ok = canonicalPackageConfig(pkgs, PathMapping({real: '/canon/workspace'}));
      expect(ok, contains('"rootUri": "file:///canon/workspace/app/"'));
      expect(
        () => canonicalPackageConfig(pkgs, PathMapping({p.join(real, 'app'): '/canon/workspace'})),
        throwsA(isA<CliException>()),
      );
    });

    test('build root: created 0700, locked, symlinks', () {
      final root = p.join(tmp.path, 'canon');
      final c = CanonicalBuildRoot.acquire({canonicalBuildRootEnv: root});
      try {
        expect(Directory(root).statSync().mode & 0x1ff, 0x1c0);
        final target = Directory(p.join(tmp.path, 'target'))..createSync();
        expect(c.link(canonWorkspace, target.path), p.join(root, canonWorkspace));
        expect(Link(p.join(root, canonWorkspace)).targetSync(), target.resolveSymbolicLinksSync());
        final other = Directory(p.join(tmp.path, 'other'))..createSync();
        c.link(canonWorkspace, other.path);
        expect(Link(p.join(root, canonWorkspace)).targetSync(), other.resolveSymbolicLinksSync());
      } finally {
        c.release();
      }
    });

    test('a build root that is a symlink is refused', () {
      final real = Directory(p.join(tmp.path, 'real'))..createSync();
      final link = Link(p.join(tmp.path, 'canon'))..createSync(real.path);
      expect(() => CanonicalBuildRoot.acquire({canonicalBuildRootEnv: link.path}), throwsA(isA<CliException>()));
    });
  });
}
