// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// TEST TOOL (not part of the `flutter_ota` command): builds a malformed-bytecode corpus in the
// PRODUCTION patch format for a device test of the bytecode verifier.
//
// Every output file is a correctly signed `dbc-v1` container (OTAPRT02) for one local release:
// the manifest is built like `flutter_ota patch` builds it, the module SHA-256 and size match,
// and it is signed with the developer's certified signer key (the CLI's own signer code). The
// server therefore accepts each file, and the device's signature, certificate and hash checks
// pass. Only the module bytes are malformed (the bc_verify regression fixtures, including B25
// and B27), so the in-VM bytecode verifier in the separate verifier process must refuse them and
// the store code must keep running.
//
//   cd packages/flutter_ota_cli
//   dart run tool/malformed_corpus.dart \
//     --release <project>/.flutter_ota/releases/<release_id> \
//     --sequence <first unused sequence> \
//     --out <output dir>
//
// Options:
//   --fixtures <dir>   malformed modules (*.bc); default: the committed bc_verify fixtures
//                      prototypes/security_hardening/tools/bc_verify/fixtures/malformed
//   --template <file>  a patch.json of a real patch of this release, whose packages and host
//                      packages are copied into every manifest; default: the newest
//                      <release>/patches/<n>/patch.json, else empty lists
//   --no-extra         do not add the synthetic cases (random bytes, a single byte)
//
// Keys come from the usual key store (FLUTTER_OTA_KEYS_DIR, FLUTTER_OTA_CONFIG_DIR or
// ~/.config/flutter_ota). The release's root keys must have certified the signer.
//
// Output: <out>/<NN>_<name>.otp (sequence = first + index) and <out>/corpus.json with each
// file's sequence, patch_id, sha256, the module's sha256 and the expected device result. Upload
// the files one by one in that order (sequences must grow with the server patch number).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/src/errors.dart';
import 'package:flutter_ota_cli/src/patch/module_builder.dart';
import 'package:flutter_ota_cli/src/patch/pipeline.dart';
import 'package:flutter_ota_cli/src/patch/release_record.dart';
import 'package:flutter_ota_cli/src/signing/key_store.dart';
import 'package:flutter_ota_cli/src/signing/patch_signer.dart';
import 'package:path/path.dart' as p;

/// One corpus file before it is written.
class CorpusEntry {
  CorpusEntry(this.name, this.sequence, this.patchId, this.module, this.container, this.expected);
  final String name;
  final int sequence;
  final String patchId;
  final Uint8List module;
  final Uint8List container;
  final String expected;

  Map<String, Object?> toJson(String file) => {
    'file': file,
    'name': name,
    'sequence': sequence,
    'patch_id': patchId,
    'sha256': sha256.convert(container).toString(),
    'module_sha256': sha256.convert(module).toString(),
    'module_size': module.length,
    'expected': expected,
  };
}

/// Expected device result per module name (bc_verify results of the fixtures).
String expectedFor(String name) {
  if (name.startsWith('17_unknown_host_class')) {
    return 'bc_verify ACCEPTS this module (known limitation L4); on the device it must fail at '
        'load or link time (the classes are not in this app); the store code keeps running';
  }
  return 'device verifier process REJECTS the module; nothing is loaded; the store code keeps running';
}

/// Seeded synthetic modules added to the fixtures.
Map<String, Uint8List> syntheticModules() {
  final rng = Random(20261113);
  return {
    'x_random_4096': Uint8List.fromList(List<int>.generate(4096, (_) => rng.nextInt(256))),
    'x_single_byte': Uint8List.fromList([0]),
  };
}

/// Builds and signs one container per module. [template] is a patch.json (or null).
List<CorpusEntry> buildMalformedCorpus({
  required ReleaseRecord release,
  required LocalSigner signer,
  required Map<String, Uint8List> modules,
  required int firstSequence,
  required DateTime now,
  Map<String, Object?>? template,
  String Function()? newPatchId,
}) {
  final manifest = template?['manifest'] as Map?;
  final packages = (manifest?['packages'] as List?) ?? const [];
  final hostPackages = ((manifest?['host_interface'] as Map?)?['host_packages'] as List?)?.cast<String>() ?? <String>[];
  final built = BuiltModule(
    modulePath: '',
    renames: {for (final x in packages.cast<Map>()) x['name'] as String: x['module_name'] as String},
    hostPackages: hostPackages,
    guardReport: null,
    verifierOutput: null,
    packageVersions: {for (final x in packages.cast<Map>()) x['name'] as String: x['version'] as String},
  );
  final out = <CorpusEntry>[];
  var sequence = firstSequence;
  for (final e in (modules.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
    final id = (newPatchId ?? randomUuidV4)();
    final m = buildManifest(
      release: release,
      module: e.value,
      built: built,
      sequence: sequence,
      patchId: id,
      keyId: signer.keyId,
      now: now,
    );
    final container = signPatch(m, e.value, signer);
    // Same check `flutter_ota patch` runs before writing: signature, root, size and hash.
    checkSignedContainer(container, signer.certificate, release.rootKeys);
    out.add(CorpusEntry(e.key, sequence, id, e.value, container, expectedFor(e.key)));
    sequence++;
  }
  return out;
}

Map<String, Object?>? _newestPatchJson(ReleaseRecord release) {
  final d = Directory(release.patchesDir);
  if (!d.existsSync()) return null;
  final found = <int, File>{};
  for (final x in d.listSync().whereType<Directory>()) {
    final n = int.tryParse(p.basename(x.path));
    final f = File(p.join(x.path, 'patch.json'));
    if (n != null && f.existsSync()) found[n] = f;
  }
  if (found.isEmpty) return null;
  final newest = found[found.keys.reduce(max)]!;
  return jsonDecode(newest.readAsStringSync()) as Map<String, Object?>;
}

String _defaultFixtures() {
  final pkg = p.dirname(p.dirname(Platform.script.toFilePath()));
  return p.normalize(
    p.join(pkg, '..', '..', 'prototypes', 'security_hardening', 'tools', 'bc_verify', 'fixtures', 'malformed'),
  );
}

Never _usage(String why) {
  stderr.writeln(
    '$why\n\nUsage: dart run tool/malformed_corpus.dart --release <dir> --sequence <n> --out <dir> '
    '[--fixtures <dir>] [--template <patch.json>] [--no-extra]',
  );
  exit(64);
}

Future<void> main(List<String> args) async {
  final opts = <String, String>{};
  var extra = true;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--no-extra') {
      extra = false;
    } else if (a.startsWith('--') && i + 1 < args.length) {
      opts[a.substring(2)] = args[++i];
    } else {
      _usage('Unknown argument: $a');
    }
  }
  final releaseDir = opts['release'] ?? _usage('--release is required');
  final outDir = opts['out'] ?? _usage('--out is required');
  final first = int.tryParse(opts['sequence'] ?? '') ?? _usage('--sequence <n> (a positive integer) is required');
  if (first < 1) _usage('--sequence must be at least 1');
  try {
    final release = ReleaseRecord.load(releaseDir);
    final now = DateTime.now().toUtc();
    final signer = loadLocalSigner(
      Platform.environment,
      appId: release.appId,
      environment: release.environment,
      now: now,
      rootPublicKeys: release.rootKeys,
    );
    final fixtures = opts['fixtures'] ?? _defaultFixtures();
    final modules = <String, Uint8List>{
      for (final f in Directory(fixtures).listSync().whereType<File>().where((f) => f.path.endsWith('.bc')))
        p.basenameWithoutExtension(f.path): f.readAsBytesSync(),
      if (extra) ...syntheticModules(),
    };
    if (modules.isEmpty) throw CliException('No *.bc modules in $fixtures.');
    final template = opts['template'] != null
        ? jsonDecode(File(opts['template']!).readAsStringSync()) as Map<String, Object?>
        : _newestPatchJson(release);
    final corpus = buildMalformedCorpus(
      release: release,
      signer: signer,
      modules: modules,
      firstSequence: first,
      now: now,
      template: template,
    );
    Directory(outDir).createSync(recursive: true);
    final index = <Map<String, Object?>>[];
    for (final (i, e) in corpus.indexed) {
      final file = '${(i + 1).toString().padLeft(2, '0')}_${e.name}.otp';
      File(p.join(outDir, file)).writeAsBytesSync(e.container, flush: true);
      index.add(e.toJson(file));
    }
    File(p.join(outDir, 'corpus.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'release_id': release.releaseId, 'app_id': release.appId, 'signer_key_id': signer.keyId, 'template': template == null ? 'none (empty packages)' : 'packages copied from a patch of this release', 'files': index})}\n',
    );
    stdout.writeln('${corpus.length} signed containers (sequences $first..${first + corpus.length - 1}) in $outDir');
  } on CliException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}
