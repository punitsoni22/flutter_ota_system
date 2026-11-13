// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'container.dart';

/// Manifest v2. Every field is required unless marked optional; unknown fields are rejected
/// (a verifier must not silently ignore data that was signed).
class PatchManifest {
  PatchManifest._(this.raw);
  final Map<String, Object?> raw;

  int get format => raw['format']! as int;
  String get appId => raw['app_id']! as String;
  String get releaseId => raw['release_id']! as String;
  String get baselineLibappSha256 => raw['baseline_libapp_sha256']! as String;
  String get patchId => raw['patch_id']! as String;
  int get sequence => raw['sequence']! as int;
  String get keyId => raw['key_id']! as String;
  String get createdAt => raw['created_at']! as String;
  String? get expiresAt => raw['expires_at'] as String?;
  Map<String, Object?> get runtime => (raw['runtime']! as Map).cast<String, Object?>();
  Map<String, Object?> get module => (raw['module']! as Map).cast<String, Object?>();
  String get moduleSha256 => module['sha256']! as String;
  int get moduleSize => module['size']! as int;
  List<Map<String, Object?>> get packages =>
      (raw['packages']! as List).map((p) => (p! as Map).cast<String, Object?>()).toList();
  Map<String, Object?> get hostInterface => (raw['host_interface']! as Map).cast<String, Object?>();
  Map<String, Object?> get toolchain => (raw['toolchain']! as Map).cast<String, Object?>();

  /// Toolchain record fields (Phase 3C provenance). `id` = SHA-256 of the canonical JSON of all
  /// other fields; the host compares it with the toolchain id it was built for.
  static const toolchainFields = {
    'flutter',
    'dart',
    'engine',
    'dart_revision',
    'engine_patch_sha256',
    'compiler_sha256',
    'generator_sha256',
    'bytecode_format',
    'build_config_sha256',
  };

  List<Map<String, Object?>> get assets =>
      (raw['assets']! as List).map((p) => (p! as Map).cast<String, Object?>()).toList();

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static final _pkg = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static final _keyId = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
  static final _version = RegExp(r'^[0-9A-Za-z.+-]{1,64}$');
  static final _isoUtc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

  static const _top = {
    'format',
    'app_id',
    'release_id',
    'baseline_libapp_sha256',
    'patch_id',
    'sequence',
    'key_id',
    'created_at',
    'expires_at',
    'runtime',
    'module',
    'packages',
    'host_interface',
    'assets',
    'toolchain',
  };
  static const _optional = {'expires_at'};

  /// Schema validation only (types, formats, limits). Compatibility is checked by the verifier.
  static PatchManifest validate(Map<String, Object?> m) {
    Never bad(String why) => throw PatchRejected('bad_manifest', why);
    for (final k in m.keys) {
      if (!_top.contains(k)) bad('unknown field "$k"');
    }
    for (final k in _top) {
      if (!_optional.contains(k) && !m.containsKey(k)) bad('missing field "$k"');
    }
    String str(Map<String, Object?> o, String k, RegExp re, String what) {
      final v = o[k];
      if (v is! String || !re.hasMatch(v)) bad('$what "$k" is invalid');
      return v;
    }

    int integer(Map<String, Object?> o, String k, int min, int max) {
      final v = o[k];
      if (v is! int || v < min || v > max) bad('integer "$k" out of range');
      return v;
    }

    Map<String, Object?> obj(Object? v, String what, Set<String> keys) {
      if (v is! Map<String, Object?>) bad('$what is not an object');
      for (final k in v.keys) {
        if (!keys.contains(k)) bad('unknown field "$what.$k"');
      }
      for (final k in keys) {
        if (!v.containsKey(k)) bad('missing field "$what.$k"');
      }
      return v;
    }

    integer(m, 'format', 2, 2);
    str(m, 'app_id', _uuid, 'uuid');
    str(m, 'release_id', _uuid, 'uuid');
    str(m, 'baseline_libapp_sha256', _sha, 'sha256');
    str(m, 'patch_id', _uuid, 'uuid');
    integer(m, 'sequence', 1, 1 << 31);
    str(m, 'key_id', _keyId, 'key id');
    str(m, 'created_at', _isoUtc, 'timestamp');
    if (m.containsKey('expires_at')) str(m, 'expires_at', _isoUtc, 'timestamp');

    final rt = obj(m['runtime'], 'runtime', {'flutter', 'dart', 'engine', 'abi', 'runtime_id'});
    for (final k in rt.keys) {
      str(rt, k, _version, 'runtime');
    }
    final mod = obj(m['module'], 'module', {'format', 'sha256', 'size', 'entry_contract'});
    if (mod['format'] != 'dart-bytecode') bad('module.format must be "dart-bytecode"');
    str(mod, 'sha256', _sha, 'sha256');
    integer(mod, 'size', 1, maxContainerBytes);
    integer(mod, 'entry_contract', 1, 1000);

    final pkgs = m['packages'];
    if (pkgs is! List || pkgs.length > 256) bad('packages must be a list of at most 256 entries');
    final seen = <String>{};
    for (final p in pkgs) {
      final o = obj(p, 'packages[]', {'name', 'module_name', 'version', 'source'});
      final name = str(o, 'name', _pkg, 'package name');
      str(o, 'module_name', _pkg, 'package name');
      str(o, 'version', _version, 'version');
      if (o['source'] != 'internal' && o['source'] != 'hosted') bad('packages[].source must be internal or hosted');
      if (!seen.add(name)) bad('duplicate package "$name"');
    }

    final hi = obj(m['host_interface'], 'host_interface', {'sha256', 'host_packages'});
    str(hi, 'sha256', _sha, 'sha256');
    final hp = hi['host_packages'];
    if (hp is! List || hp.length > 512 || hp.any((e) => e is! String || !_pkg.hasMatch(e))) {
      bad('host_interface.host_packages is invalid');
    }

    final assets = m['assets'];
    if (assets is! List || assets.length > 1024) bad('assets must be a list of at most 1024 entries');
    for (final a in assets) {
      final o = obj(a, 'assets[]', {'key', 'sha256', 'size'});
      final key = o['key'];
      if (key is! String ||
          key.isEmpty ||
          key.length > 256 ||
          key.startsWith('/') ||
          key.contains('..') ||
          key.contains('\\')) {
        bad('asset key is invalid');
      }
      str(o, 'sha256', _sha, 'sha256');
      integer(o, 'size', 0, maxContainerBytes);
    }
    final tc = obj(m['toolchain'], 'toolchain', {'id', ...toolchainFields});
    str(tc, 'id', _sha, 'sha256');
    for (final k in const ['engine_patch_sha256', 'compiler_sha256', 'generator_sha256', 'build_config_sha256']) {
      str(tc, k, _sha, 'sha256');
    }
    for (final k in const ['flutter', 'dart', 'engine', 'dart_revision']) {
      str(tc, k, _version, 'version');
    }
    integer(tc, 'bytecode_format', 1, 1000);
    return PatchManifest._(m);
  }
}
