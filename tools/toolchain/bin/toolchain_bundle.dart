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
        ..addOption('sdk-unpacked-size')
        ..addFlag(
          'release-layout',
          help:
              'GitHub Releases layout: every file flat in --out-dir (toolchain-index.json, the '
              'overlay, toolchain-manifest.json, SHA256SUMS).',
        ),
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
  final releaseLayout = c['release-layout'] as bool;
  final rel = releaseLayout ? '$name-linux-x64.tar.gz' : 'overlays/$name-linux-x64.tar.gz';
  Directory(p.dirname(p.join(outDir, rel))).createSync(recursive: true);
  final overlay = await buildOverlay(
    labDir: lab,
    outFile: p.join(outDir, rel),
    toolchainName: name,
    engineCommit: engine,
    flutterVersion: flutter,
    notices: notices,
    dynamicModulesDir: p.join(repo, 'prototypes', 'real_app_compatibility', 'packages', 'dynamic_modules'),
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
  final indexFile = File(p.join(outDir, releaseLayout ? 'toolchain-index.json' : 'index.json'));
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
  if (releaseLayout) {
    await _writeReleaseFiles(outDir, indexFile, serial, keyId, key.publicKeyBase64, entry, overlay);
  }
}

/// Human-readable manifest and checksums for a GitHub release. The signed index stays the only
/// file the CLI trusts; these let a person check the assets by hand.
///
/// The manifest lists every toolchain of the index (format 2). Entries of toolchains built earlier
/// into the same folder are kept, so several Flutter versions can share one release.
Future<void> _writeReleaseFiles(
  String outDir,
  File indexFile,
  int serial,
  String keyId,
  String publicKey,
  Map<String, Object?> entry,
  OverlayBuildResult overlay,
) async {
  final artifacts = entry['artifacts']! as Map;
  final mine = {
    'toolchain': entry['id'],
    'toolchain_id': entry['toolchain_id'],
    'flutter': entry['flutter'],
    'dart': entry['dart'],
    'engine_commit': entry['engine'],
    'engine_build_id': overlay.engineBuildId,
    'host': entry['host'],
    'target': entry['target'],
    'flutter_sdk': artifacts['flutter_sdk'],
    'overlay': {'file': p.basename(overlay.path), 'sha256': overlay.sha256, 'size': overlay.size},
  };
  final manifestFile = File(p.join(outDir, 'toolchain-manifest.json'));
  final indexed = {
    for (final t in ((jsonDecode(indexFile.readAsStringSync()) as Map)['index'] as Map)['toolchains'] as List)
      (t as Map)['id'] as String,
  };
  final toolchains = <Map<String, Object?>>[];
  if (manifestFile.existsSync()) {
    final old = jsonDecode(manifestFile.readAsStringSync()) as Map;
    // Format 1 described one toolchain at the top level; format 2 lists them.
    final previous = old['format'] == 1 ? [old] : (old['toolchains'] as List? ?? const []);
    for (final t in previous.cast<Map>()) {
      final id = t['toolchain'];
      if (id != entry['id'] && indexed.contains(id)) {
        toolchains.add({for (final k in mine.keys) k: t[k]});
      }
    }
  }
  toolchains
    ..add(mine)
    ..sort((a, b) => '${a['toolchain']}'.compareTo('${b['toolchain']}'));
  final manifest = {
    'format': 2,
    'index': {
      'file': p.basename(indexFile.path),
      'serial': serial,
      'signed_by': keyId,
      'public_key': publicKey,
      'sha256': await sha256OfFile(indexFile.path),
    },
    'toolchains': toolchains,
  };
  manifestFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
  final sums = StringBuffer();
  final files = [
    for (final t in toolchains) (t['overlay']! as Map)['file'] as String,
    p.basename(indexFile.path),
    p.basename(manifestFile.path),
  ];
  for (final f in files) {
    sums.writeln('${await sha256OfFile(p.join(outDir, f))}  $f');
  }
  File(p.join(outDir, 'SHA256SUMS')).writeAsStringSync(sums.toString());
  stdout.writeln(
    'release files: toolchain-manifest.json (${toolchains.length} toolchains), SHA256SUMS '
    '(engine build ID ${overlay.engineBuildId})',
  );
}
