// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show ECPublicKey;

import '../errors.dart';
import 'canonical_json.dart';
import 'es256.dart';

/// The only host the toolchain binaries (gen_snapshot, tool snapshots) are built for.
const supportedHost = 'linux-x64';

final _idPattern = RegExp(r'^[a-z0-9][a-z0-9._+-]{0,63}$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _hexPattern = RegExp(r'^[0-9a-f]{7,64}$');

/// One downloadable archive of a toolchain.
class ToolchainArtifact {
  ToolchainArtifact({
    required this.url,
    required this.sha256,
    required this.size,
    required this.format,
    this.root,
    this.unpackedSize,
  });

  factory ToolchainArtifact.fromJson(Map<String, Object?> j, Uri base) {
    final url = _str(j, 'url');
    final sha = _str(j, 'sha256');
    final size = j['size'];
    final format = _str(j, 'format');
    if (!_sha256Pattern.hasMatch(sha)) throw const FormatException('artifact sha256 must be 64 lowercase hex');
    if (size is! int || size <= 0) throw const FormatException('artifact size must be a positive integer');
    if (!const {'tar.gz', 'tar.xz'}.contains(format)) throw FormatException('unsupported archive format $format');
    final unpacked = j['unpacked_size'];
    if (unpacked != null && (unpacked is! int || unpacked <= 0)) {
      throw const FormatException('unpacked_size must be a positive integer');
    }
    final root = j['root'];
    if (root != null && (root is! String || root.contains('/') || root.startsWith('.'))) {
      throw const FormatException('artifact root must be a single directory name');
    }
    return ToolchainArtifact(
      // Relative URLs are resolved against the index URL, so a mirror is a plain copy of a folder.
      url: base.resolve(url),
      sha256: sha,
      size: size,
      format: format,
      root: root as String?,
      unpackedSize: unpacked as int?,
    );
  }

  final Uri url;
  final String sha256;
  final int size;
  final String format;

  /// Top-level directory inside the archive (for the stock SDK: `flutter`).
  final String? root;
  final int? unpackedSize;

  /// Space needed to extract it (falls back to a conservative estimate).
  int get extractEstimate => unpackedSize ?? size * 4;
}

/// One supported toolchain: a pinned stock Flutter SDK plus our overlay.
class ToolchainEntry {
  ToolchainEntry({
    required this.id,
    required this.toolchainId,
    required this.flutter,
    required this.dart,
    required this.engine,
    required this.dartRevision,
    required this.host,
    required this.target,
    required this.sdk,
    required this.overlay,
  });

  factory ToolchainEntry.fromJson(Map<String, Object?> j, Uri base) {
    final id = _str(j, 'id');
    if (!_idPattern.hasMatch(id)) throw FormatException('invalid toolchain id "$id"');
    final tid = _str(j, 'toolchain_id');
    if (!_sha256Pattern.hasMatch(tid)) throw const FormatException('toolchain_id must be 64 lowercase hex');
    final engine = _str(j, 'engine');
    final dartRev = _str(j, 'dart_revision');
    if (!_hexPattern.hasMatch(engine) || !_hexPattern.hasMatch(dartRev)) {
      throw const FormatException('engine and dart_revision must be hex commit ids');
    }
    final artifacts = j['artifacts'];
    if (artifacts is! Map<String, Object?>) throw const FormatException('artifacts missing');
    Map<String, Object?> art(String k) {
      final a = artifacts[k];
      if (a is! Map<String, Object?>) throw FormatException('artifact "$k" missing');
      return a;
    }

    return ToolchainEntry(
      id: id,
      toolchainId: tid,
      flutter: _str(j, 'flutter'),
      dart: _str(j, 'dart'),
      engine: engine,
      dartRevision: dartRev,
      host: _str(j, 'host'),
      target: _str(j, 'target'),
      sdk: ToolchainArtifact.fromJson(art('flutter_sdk'), base),
      overlay: ToolchainArtifact.fromJson(art('overlay'), base),
    );
  }

  final String id;
  final String toolchainId;
  final String flutter;
  final String dart;
  final String engine;
  final String dartRevision;
  final String host;
  final String target;
  final ToolchainArtifact sdk;
  final ToolchainArtifact overlay;
}

/// A verified toolchain index.
class ToolchainIndex {
  ToolchainIndex({required this.toolchains, required this.signedBy, required this.source, required this.serial});

  /// Increases with every published index; a lower serial than one seen before is refused
  /// (protection against replaying an old, signed index).
  final int serial;

  final List<ToolchainEntry> toolchains;

  /// Key id of the trusted key whose signature verified.
  final String signedBy;
  final Uri source;

  ToolchainEntry? byId(String id) {
    for (final t in toolchains) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Toolchains this host can use, in index order (the owner lists the newest last).
  List<ToolchainEntry> get compatible => [
    for (final t in toolchains)
      if (t.host == supportedHost) t,
  ];

  /// Verifies the signed envelope [bytes] against [trustedKeys] (key id -> base64 public key)
  /// and parses it. Verification is never skipped: an unsigned, unknown-key or bad signature is
  /// an [IndexVerificationException].
  ///
  /// Envelope: `{"format":1,"index":{...},"signatures":[{"key_id":"..","signature":".."}]}`.
  /// The signed message is [toolchainIndexDomain] followed by the canonical JSON of `index`.
  static ToolchainIndex verifyAndParse(Uint8List bytes, Map<String, String> trustedKeys, Uri source) {
    if (trustedKeys.isEmpty) {
      throw IndexVerificationException(
        'No trusted toolchain-signing keys are configured, so the toolchain index cannot be verified.\n'
        'Add the public key of whoever built your toolchain:\n'
        '  flutter_ota config add-toolchain-key <key_id> <public_key_base64>',
      );
    }
    final Object? envelope;
    try {
      envelope = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw IndexVerificationException('toolchain index at $source is not valid JSON');
    }
    if (envelope is! Map<String, Object?> || envelope['format'] != 1) {
      throw IndexVerificationException('toolchain index at $source has an unsupported format');
    }
    final index = envelope['index'];
    final sigs = envelope['signatures'];
    if (index is! Map<String, Object?> || sigs is! List || sigs.isEmpty) {
      throw IndexVerificationException('toolchain index at $source is not signed');
    }
    final Uint8List message;
    try {
      message = domainMessage(toolchainIndexDomain, canonicalJson(index));
    } on FormatException catch (e) {
      throw IndexVerificationException('toolchain index at $source is not canonical JSON: ${e.message}');
    }
    final keys = <String, ECPublicKey>{};
    trustedKeys.forEach((id, b64) {
      try {
        keys[id] = parseEs256PublicKey(b64);
      } on FormatException {
        // An invalid configured key can never verify anything; ignore it.
      }
    });
    String? signedBy;
    final unknown = <String>[];
    var badSignature = false;
    for (final s in sigs) {
      if (s is! Map || s['key_id'] is! String || s['signature'] is! String) continue;
      final key = keys[s['key_id']];
      if (key == null) {
        unknown.add(s['key_id'] as String);
        continue;
      }
      if (es256Verify(key, message, s['signature'] as String)) {
        signedBy = s['key_id'] as String;
        break;
      }
      badSignature = true;
    }
    if (signedBy == null) {
      if (badSignature) {
        throw IndexVerificationException(
          'toolchain index at $source has an INVALID signature (it was changed after signing, '
          'or signed with a different key). Refusing to use it.',
        );
      }
      throw IndexVerificationException(
        'toolchain index at $source is signed only by unknown key(s) '
        '${unknown.join(', ')}. Trust a key with: flutter_ota config add-toolchain-key <key_id> <public_key_base64>',
      );
    }
    final list = index['toolchains'];
    if (list is! List) throw IndexVerificationException('toolchain index has no toolchains list');
    final serial = index['serial'];
    if (serial is! int || serial < 1) throw IndexVerificationException('toolchain index has no valid serial');
    try {
      final entries = [for (final t in list) ToolchainEntry.fromJson(t as Map<String, Object?>, source)];
      final ids = entries.map((e) => e.id).toSet();
      if (ids.length != entries.length) throw const FormatException('duplicate toolchain id');
      return ToolchainIndex(toolchains: entries, signedBy: signedBy, source: source, serial: serial);
    } on FormatException catch (e) {
      throw IndexVerificationException('toolchain index entry is invalid: ${e.message}');
    } on TypeError {
      throw IndexVerificationException('toolchain index entry is invalid');
    }
  }
}

String _str(Map<String, Object?> j, String key) {
  final v = j[key];
  if (v is! String || v.isEmpty) throw FormatException('"$key" must be a non-empty string');
  return v;
}
