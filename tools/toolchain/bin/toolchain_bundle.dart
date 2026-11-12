// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Owner-side toolchain bundle tool. Usually run through ../build_bundle.sh.
//
//   keygen  --key-dir DIR --key-id ID
//   build   --lab DIR --pins FILE --repo DIR --name ID --out-dir DIR --key-dir DIR --key-id ID
//           --sdk-url URL --sdk-sha256 HEX --sdk-size N [--sdk-unpacked-size N]
//   verify  --index FILE --pub FILE --key-id ID

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_ota_cli/flutter_ota_cli.dart' show ToolchainIndex;
import 'package:flutter_ota_cli/owner.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addCommand(
      'keygen',
      ArgParser()
        ..addOption('key-dir', mandatory: true)
        ..addOption('key-id', mandatory: true),
    )
    ..addCommand(
      'build',
      ArgParser()
        ..addOption('lab', mandatory: true)
        ..addOption('pins', mandatory: true)
        ..addOption('repo', mandatory: true)
        ..addOption('name', mandatory: true)
        ..addOption('out-dir', mandatory: true)
        ..addOption('key-dir', mandatory: true)
        ..addOption('key-id', mandatory: true)
        ..addOption('sdk-url', mandatory: true)
        ..addOption('sdk-sha256', mandatory: true)
        ..addOption('sdk-size', mandatory: true)
        ..addOption('sdk-unpacked-size'),
    )
    ..addCommand(
      'verify',
      ArgParser()
        ..addOption('index', mandatory: true)
        ..addOption('pub', mandatory: true)
        ..addOption('key-id', mandatory: true),
    );
  final ArgResults args;
  try {
    args = parser.parse(argv);
    if (args.command == null) throw const FormatException('expected keygen, build or verify');
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n${parser.usage}');
    exitCode = 64;
    return;
  }
  final c = args.command!;
  switch (c.name) {
    case 'keygen':
      final key = await generateKeyFiles(c['key-dir'] as String, c['key-id'] as String);
      stdout.writeln(
        'Created ${p.join(c['key-dir'] as String, '${c['key-id']}.key')} (keep it secret, never commit it)',
      );
      stdout.writeln('Public key (${c['key-id']}): ${key.publicKeyBase64}');
    case 'build':
      await _build(c);
    case 'verify':
      final pub = File(c['pub'] as String).readAsStringSync().trim();
      final index = ToolchainIndex.verifyAndParse(File(c['index'] as String).readAsBytesSync(), {
        c['key-id'] as String: pub,
      }, Uri.file(p.absolute(c['index'] as String)));
      stdout.writeln(
        'OK: serial ${index.serial}, signed by ${index.signedBy}, '
        'toolchains: ${index.toolchains.map((t) => t.id).join(', ')}',
      );
  }
}

Map<String, String> _readPins(String path) {
  final out = <String, String>{};
  for (final line in File(path).readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#') || !t.contains('=')) continue;
    final i = t.indexOf('=');
    out[t.substring(0, i).trim()] = t.substring(i + 1).trim();
  }
  return out;
}

Future<void> _build(ArgResults c) async {
  final lab = c['lab'] as String;
  final repo = c['repo'] as String;
  final pins = _readPins(c['pins'] as String);
  final name = c['name'] as String;
  final outDir = c['out-dir'] as String;
  final keyId = c['key-id'] as String;
  final keyPath = p.join(c['key-dir'] as String, '$keyId.key');
  if (p.isWithin(p.absolute(repo), p.absolute(keyPath))) {
    throw StateError('the signing key must live outside the repository');
  }
  final key = readPrivateKey(keyPath);
  final engine = pins['ENGINE_COMMIT']!;
  final flutter = pins['FLUTTER_VERSION']!;
  final engineSrc = p.join(lab, 'engine', 'engine', 'src', 'flutter');
  final notices = {
    'LICENSE.flutter': p.join(lab, 'flutter', 'LICENSE'),
    'LICENSE.dart': p.join(engineSrc, 'third_party', 'dart', 'LICENSE'),
    'LICENSE.engine-third-party': p.join(engineSrc, 'sky', 'packages', 'sky_engine', 'LICENSE'),
    'LICENSE.flutter-ota-system': p.join(repo, 'LICENSE'),
    'NOTICE.flutter-ota-system': p.join(repo, 'NOTICE'),
  };
  Directory(p.join(outDir, 'overlays')).createSync(recursive: true);
  final rel = 'overlays/$name-linux-x64.tar.gz';
  final overlay = await buildOverlay(
    labDir: lab,
    outFile: p.join(outDir, rel),
    toolchainName: name,
    engineCommit: engine,
    flutterVersion: flutter,
    notices: notices,
    log: stdout.writeln,
  );
  final entry = indexEntry(
    id: name,
    toolchainId: overlay.toolchainId,
    flutter: flutter,
    dart: pins['DART_VERSION']!,
    engine: engine,
    dartRevision: pins['DART_REVISION']!,
    sdk: {
      'url': c['sdk-url'],
      'sha256': c['sdk-sha256'],
      'size': int.parse(c['sdk-size'] as String),
      if (c['sdk-unpacked-size'] != null) 'unpacked_size': int.parse(c['sdk-unpacked-size'] as String),
      'format': (c['sdk-url'] as String).endsWith('.tar.xz') ? 'tar.xz' : 'tar.gz',
      'root': 'flutter',
    },
    overlay: {
      'url': rel,
      'sha256': overlay.sha256,
      'size': overlay.size,
      'unpacked_size': overlay.unpackedSize,
      'format': 'tar.gz',
    },
  );
  // Keep the other entries of an existing index signed by the same key; bump the serial.
  final indexFile = File(p.join(outDir, 'index.json'));
  var serial = 1;
  final entries = <Object?>[];
  if (indexFile.existsSync()) {
    final old = ToolchainIndex.verifyAndParse(indexFile.readAsBytesSync(), {
      keyId: key.publicKeyBase64,
    }, Uri.file(p.absolute(indexFile.path)));
    serial = old.serial + 1;
    final raw = (jsonDecode(indexFile.readAsStringSync()) as Map)['index'] as Map;
    entries.addAll((raw['toolchains'] as List).where((t) => (t as Map)['id'] != name));
  }
  entries.add(entry);
  indexFile.writeAsBytesSync(signIndex({'serial': serial, 'toolchains': entries}, keyId, key));
  stdout.writeln('index: ${indexFile.path} (serial $serial, signed by $keyId)');
  stdout.writeln('toolchain_id: ${overlay.toolchainId}');
  stdout.writeln('public key ($keyId): ${key.publicKeyBase64}');
}
