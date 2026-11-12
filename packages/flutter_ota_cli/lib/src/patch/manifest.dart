// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Patch manifest v2. The schema is a strict port of the source of truth,
// prototypes/security_hardening/packages/patch_security/lib/src/manifest.dart: the CLI validates
// every manifest before it signs it, so it never signs something the device would refuse as
// malformed. A test runs patch_security's verifyPatch on the CLI's output.

import 'package:crypto/crypto.dart';

import '../errors.dart';
import '../toolchain/canonical_json.dart';
import 'container.dart';

/// Toolchain record fields (the `id` is SHA-256 of the canonical JSON of these).
const toolchainRecordFields = {
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

/// Entry contract of Phase 4 modules (names -> factories).
const entryContract = 3;

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
final _sha = RegExp(r'^[0-9a-f]{64}$');
final _pkg = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final _keyId = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final _version = RegExp(r'^[0-9A-Za-z.+-]{1,64}$');
final _isoUtc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

bool isUuid(String s) => _uuid.hasMatch(s);
bool isPackageName(String s) => _pkg.hasMatch(s);
bool isManifestVersion(String s) => _version.hasMatch(s);

const _top = {
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

/// SHA-256 id of a toolchain record (all fields except `id`).
String toolchainRecordId(Map<String, Object?> record) =>
    sha256.convert(canonicalJson({for (final k in toolchainRecordFields) k: record[k]})).toString();

/// Validates [m] against the manifest v2 schema. Throws [CliException] (`bad_manifest: ...`).
void validatePatchManifest(Map<String, Object?> m) {
  Never bad(String why) => throw CliException('bad_manifest: $why (this is a CLI bug; please report it)');
  for (final k in m.keys) {
    if (!_top.contains(k)) bad('unknown field "$k"');
  }
  for (final k in _top) {
    if (k != 'expires_at' && !m.containsKey(k)) bad('missing field "$k"');
  }
  String str(Map<String, Object?> o, String k, RegExp re, String what) {
    final v = o[k];
    if (v is! String || !re.hasMatch(v)) bad('$what "$k" is invalid');
    return v;
  }

  void integer(Map<String, Object?> o, String k, int min, int max) {
    final v = o[k];
    if (v is! int || v < min || v > max) bad('integer "$k" out of range');
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
  for (final x in pkgs) {
    final o = obj(x, 'packages[]', {'name', 'module_name', 'version', 'source'});
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
  if (assets is! List || assets.isNotEmpty) bad('assets must be an empty list (patches carry no assets yet)');
  final tc = obj(m['toolchain'], 'toolchain', {'id', ...toolchainRecordFields});
  str(tc, 'id', _sha, 'sha256');
  for (final k in const ['engine_patch_sha256', 'compiler_sha256', 'generator_sha256', 'build_config_sha256']) {
    str(tc, k, _sha, 'sha256');
  }
  for (final k in const ['flutter', 'dart', 'engine', 'dart_revision']) {
    str(tc, k, _version, 'version');
  }
  integer(tc, 'bytecode_format', 1, 1000);
  if (toolchainRecordId(tc) != tc['id']) bad('toolchain id does not match its fields');
}
