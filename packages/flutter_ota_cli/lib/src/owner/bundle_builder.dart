// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../toolchain/canonical_json.dart';
import '../toolchain/downloader.dart' show sha256OfFile;
import '../toolchain/es256.dart';
import '../toolchain/index.dart' show supportedHost;
import '../toolchain/records.dart';

/// Owner-side: builds the overlay archive and the signed toolchain index from a lab toolchain
/// (layout of `~/.cache/flutter-ota-lab`, see prototypes/bytecode_engine/scripts/prepare_toolchain.sh):
///
///     <lab>/flutter/<gen_snapshot path>          our interpreter-enabled gen_snapshot
///     <lab>/flutter/<gen_snapshot path>.stock    the stock one it replaced
///     <lab>/mirror/download.flutter.io/...       Maven mirror with our libflutter jar + POMs
///     <lab>/work/tools/{dart2bytecode,pkg_rename,patch_guard}.aot
///     <lab>/work/toolchain.json                  content-hash toolchain record
class OverlayBuildResult {
  OverlayBuildResult(this.path, this.sha256, this.size, this.unpackedSize, this.toolchainId);
  final String path;
  final String sha256;
  final int size;
  final int unpackedSize;
  final String toolchainId;
}

Future<OverlayBuildResult> buildOverlay({
  required String labDir,
  required String outFile,
  required String toolchainName,
  required String engineCommit,
  required String flutterVersion,
  required Map<String, String> notices,
  void Function(String)? log,
}) async {
  final stage = Directory('$outFile.stage');
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);
  final files = <String, Map<String, Object?>>{};

  Future<void> add(String src, String rel, {bool executable = false}) async {
    final s = File(src);
    if (!s.existsSync()) throw StateError('missing input: $src');
    final dst = File(p.join(stage.path, rel));
    dst.parent.createSync(recursive: true);
    s.copySync(dst.path);
    await Process.run('chmod', [executable ? '0755' : '0644', dst.path]);
    files[rel] = {'sha256': await sha256OfFile(dst.path), 'size': dst.lengthSync()};
  }

  // toolchain.json: must be a valid content-hash record for this engine.
  final tjPath = p.join(labDir, 'work', 'toolchain.json');
  final tj = jsonDecode(File(tjPath).readAsStringSync()) as Map<String, Object?>;
  final toolchainId = tj['id'] as String;
  if (computeToolchainId(tj) != toolchainId) throw StateError('toolchain.json id does not match its content');
  if (!engineCommit.startsWith(tj['engine'] as String) || tj['flutter'] != flutterVersion) {
    throw StateError('toolchain.json is for engine ${tj['engine']} / Flutter ${tj['flutter']}');
  }
  await add(tjPath, 'toolchain.json');

  final gs = p.join(labDir, 'flutter', genSnapshotSdkPath);
  final stockSha = await sha256OfFile('$gs.stock');
  if (await sha256OfFile(gs) == stockSha) throw StateError('lab gen_snapshot is still the stock binary');
  await add(gs, 'sdk/$genSnapshotSdkPath', executable: true);

  for (final m in mirrorFilesFor(engineCommit)) {
    await add(p.join(labDir, m), m);
  }
  for (final t in toolSnapshots) {
    await add(p.join(labDir, 'work', 'tools', '$t.aot'), 'tools/$t.aot');
  }
  for (final n in notices.entries) {
    await add(n.value, 'NOTICES/${n.key}');
  }
  final readme = File(p.join(stage.path, 'NOTICES', 'README.txt'));
  readme.parent.createSync(recursive: true);
  readme.writeAsStringSync('''
Flutter OTA System toolchain overlay $toolchainName (experimental alpha).

This overlay is applied by `flutter_ota toolchain install` to a stock Flutter $flutterVersion SDK.
It contains:
  - gen_snapshot (android-arm64-release, linux-x64 host) and libflutter.so (inside the Maven
    mirror jar) built from the Flutter engine at $engineCommit with the Dart bytecode
    interpreter enabled and the patch in prototypes/bytecode_engine/engine_patch/ applied.
    The Flutter engine and the Dart SDK are BSD-3-Clause licensed: see LICENSE.flutter,
    LICENSE.dart and the third-party notices in LICENSE.engine-third-party.
  - The official, unmodified flutter_embedding_release jar and POMs (BSD-3-Clause, Flutter).
  - Tool snapshots: dart2bytecode (Dart SDK, BSD-3-Clause), pkg_rename and patch_guard
    (Flutter OTA System, Apache-2.0, see LICENSE.flutter-ota-system and NOTICE.flutter-ota-system).
''');
  files['NOTICES/README.txt'] = {'sha256': await sha256OfFile(readme.path), 'size': readme.lengthSync()};

  final manifest = {
    'format': 1,
    'toolchain': toolchainName,
    'toolchain_id': toolchainId,
    'flutter': flutterVersion,
    'engine': engineCommit,
    'host': supportedHost,
    'files': files,
    'sdk_replacements': {
      genSnapshotSdkPath: {'stock_sha256': stockSha},
    },
  };
  File(
    p.join(stage.path, overlayManifestName),
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');

  // Deterministic archive: sorted names, fixed mtime/owner, gzip without a timestamp.
  final tarFile = '$outFile.tar';
  var r = await Process.run('tar', [
    '--sort=name',
    '--mtime=@0',
    '--owner=0',
    '--group=0',
    '--numeric-owner',
    '--format=gnu',
    '--mode=u+rw,go-w,go+r', //
    '-cf', tarFile, '-C', stage.path, '.',
  ]);
  if (r.exitCode != 0) throw StateError('tar failed: ${r.stderr}');
  r = await Process.run('sh', ['-c', 'gzip -n -9 -c "\$1" > "\$2"', 'sh', tarFile, outFile]);
  if (r.exitCode != 0) throw StateError('gzip failed: ${r.stderr}');
  final unpacked = File(tarFile).lengthSync();
  File(tarFile).deleteSync();
  stage.deleteSync(recursive: true);
  final sha = await sha256OfFile(outFile);
  log?.call('overlay: $outFile ${File(outFile).lengthSync()} bytes sha256 $sha');
  return OverlayBuildResult(outFile, sha, File(outFile).lengthSync(), unpacked, toolchainId);
}

/// A toolchain entry of the index (JSON object, see `ToolchainEntry.fromJson`).
Map<String, Object?> indexEntry({
  required String id,
  required String toolchainId,
  required String flutter,
  required String dart,
  required String engine,
  required String dartRevision,
  required Map<String, Object?> sdk,
  required Map<String, Object?> overlay,
}) => {
  'id': id,
  'toolchain_id': toolchainId,
  'flutter': flutter,
  'dart': dart,
  'engine': engine,
  'dart_revision': dartRevision,
  'host': supportedHost,
  'target': 'android-arm64',
  'artifacts': {'flutter_sdk': sdk, 'overlay': overlay},
};

/// Signs an index body and returns the envelope bytes.
Uint8List signIndex(Map<String, Object?> index, String keyId, Es256KeyPair key) {
  final message = domainMessage(toolchainIndexDomain, canonicalJson(index));
  final envelope = {
    'format': 1,
    'index': index,
    'signatures': [
      {'key_id': keyId, 'signature': key.sign(message)},
    ],
  };
  return Uint8List.fromList(utf8.encode('${const JsonEncoder.withIndent('  ').convert(envelope)}\n'));
}

/// Creates `<dir>/<keyId>.key` (private, mode 0600) and `<dir>/<keyId>.pub`. Refuses to overwrite.
Future<Es256KeyPair> generateKeyFiles(String dir, String keyId) async {
  final priv = File(p.join(dir, '$keyId.key'));
  if (priv.existsSync()) throw StateError('${priv.path} already exists');
  Directory(dir).createSync(recursive: true);
  await Process.run('chmod', ['0700', dir]);
  final key = Es256KeyPair.generate();
  priv.writeAsStringSync('');
  await Process.run('chmod', ['0600', priv.path]);
  priv.writeAsStringSync('${key.privateKeyBase64}\n');
  File(p.join(dir, '$keyId.pub')).writeAsStringSync('${key.publicKeyBase64}\n');
  return key;
}

Es256KeyPair readPrivateKey(String path) => Es256KeyPair.fromPrivateBase64(File(path).readAsStringSync());
