// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Build-time configuration of the bytecode runtime (runtime contract, section 1).
//
// The CLI injects ONE dart-define, FLUTTER_OTA_CONFIG = base64url(canonical JSON). It holds only
// public values: ids, the server URL, root PUBLIC keys and the identity of the toolchain. Parsing
// never throws: a missing or invalid value disables OTA with a reason.

import 'dart:convert';
import 'dart:typed_data';

import '../security/security.dart';

/// The parsed `FLUTTER_OTA_CONFIG` value.
class FlutterOtaConfig {
  FlutterOtaConfig._({
    required this.appId,
    required this.serverUrl,
    required this.releaseId,
    required this.environment,
    required this.rootKeys,
    required this.toolchainId,
    required this.runtime,
    required this.interfaceSha256,
    required this.hostPackages,
    required this.entryContract,
    required this.releaseVersion,
    required this.channel,
    required this.requiredApprovals,
    required this.hostOwnedPackages,
  });

  /// The only entry-point contract this SDK version runs (contract section 4).
  static const supportedEntryContract = 3;

  /// The only config format this SDK version reads.
  static const supportedFormat = 1;

  /// Packages a patch may never carry, whatever the config says: the framework, the module
  /// loader and this SDK are always part of the store build.
  static const alwaysHostOwned = {'flutter', 'sky_engine', 'dynamic_modules', 'flutter_ota_system'};

  /// Server application id (UUID).
  final String appId;

  /// Base URL of the self-hosted server. Release builds require `https://` (checked per request).
  final String serverUrl;

  /// Backend release id (UUID) of this store build.
  final String releaseId;

  /// Trust environment of certificates, e.g. `production`.
  final String environment;

  /// Root public keys: key id -> base64 uncompressed P-256 point.
  final Map<String, String> rootKeys;

  /// SHA-256 id of the toolchain whose patches this build accepts.
  final String toolchainId;

  /// Runtime identity (`abi`, `dart`, `engine`, `flutter`, `runtime_id`).
  final Map<String, String> runtime;

  /// SHA-256 of the dynamic interface the store build was compiled with.
  final String interfaceSha256;

  /// Packages that exist in the store build (a patch may import them).
  final Set<String> hostPackages;

  /// Entry-point contract of patch modules (always [supportedEntryContract]).
  final int entryContract;

  /// Optional: the store version as registered on the server (`1.0.0+1`). When absent, the SDK
  /// asks Android (`versionName+versionCode`).
  final String? releaseVersion;

  /// Optional: update channel (default `production`).
  final String channel;

  /// Optional: how many approver signatures a patch needs (default 0).
  final int requiredApprovals;

  /// Packages a patch may not carry ([alwaysHostOwned] plus optional `host_owned_packages`).
  final Set<String> hostOwnedPackages;

  /// The certificate trust of this build. `dbc-v1` patches must be signed by a certified key.
  CertificateTrust certificateTrust() => CertificateTrust(
    roots: Es256Verifier(rootKeys),
    environment: environment,
    requiredApprovals: requiredApprovals,
    requireCertificates: true,
  );

  /// The store build's identity for [verifyPatch]. [libappSha256] is computed on the device.
  HostIdentity hostIdentity(String libappSha256) => HostIdentity(
    appId: appId,
    releaseId: releaseId,
    baselineLibappSha256: libappSha256,
    runtime: runtime,
    interfaceSha256: interfaceSha256,
    hostPackages: hostPackages,
    hostOwnedPackages: hostOwnedPackages,
    entryContract: entryContract,
    toolchainId: toolchainId,
  );

  static const _required = {
    'format',
    'app_id',
    'server_url',
    'release_id',
    'environment',
    'root_keys',
    'toolchain_id',
    'runtime',
    'interface_sha256',
    'host_packages',
    'entry_contract',
  };
  static const _optional = {'release_version', 'channel', 'required_approvals', 'host_owned_packages'};
  static const _runtimeKeys = {'abi', 'dart', 'engine', 'flutter', 'runtime_id'};

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static final _pkg = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static final _keyId = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
  static final _version = RegExp(r'^[0-9A-Za-z.+-]{1,64}$');
  static final _name = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

  /// Parses [define] (the raw dart-define value). Returns the config, or a reason why OTA is off.
  /// Never throws.
  static ConfigResult parse(String define) {
    if (define.trim().isEmpty) {
      return const ConfigResult.disabled('FLUTTER_OTA_CONFIG is not set (for example a plain `flutter run`)');
    }
    try {
      final Uint8List bytes;
      try {
        bytes = base64Url.decode(base64Url.normalize(define.trim()));
      } on FormatException {
        return const ConfigResult.disabled('FLUTTER_OTA_CONFIG is not base64url');
      }
      final Map<String, Object?> j;
      try {
        j = parseCanonicalObject(bytes);
      } on FormatException catch (e) {
        return ConfigResult.disabled('FLUTTER_OTA_CONFIG is not canonical JSON: ${e.message}');
      }
      return _fromJson(j);
    } on _Bad catch (e) {
      return ConfigResult.disabled('FLUTTER_OTA_CONFIG is invalid: ${e.why}');
    } catch (e) {
      return ConfigResult.disabled('FLUTTER_OTA_CONFIG could not be read: ${e.runtimeType}');
    }
  }

  static ConfigResult _fromJson(Map<String, Object?> j) {
    final warnings = <String>[];
    for (final k in j.keys) {
      if (!_required.contains(k) && !_optional.contains(k)) warnings.add('unknown field "$k" ignored');
    }
    for (final k in _required) {
      if (!j.containsKey(k)) throw _Bad('missing field "$k"');
    }
    String str(Map<String, Object?> o, String k, RegExp re) {
      final v = o[k];
      if (v is! String || !re.hasMatch(v)) throw _Bad('"$k" is invalid');
      return v;
    }

    if (j['format'] != supportedFormat) {
      throw _Bad('format ${j['format']} is not supported (expected $supportedFormat)');
    }
    if (j['entry_contract'] != supportedEntryContract) {
      throw _Bad('entry_contract ${j['entry_contract']} is not supported (expected $supportedEntryContract)');
    }
    final server = j['server_url'];
    final serverUri = server is String ? Uri.tryParse(server) : null;
    if (serverUri == null || !(serverUri.isScheme('https') || serverUri.isScheme('http')) || serverUri.host.isEmpty) {
      throw _Bad('"server_url" is not an http(s) URL');
    }
    final roots = j['root_keys'];
    if (roots is! Map<String, Object?> || roots.isEmpty || roots.length > 16) {
      throw _Bad('"root_keys" must hold 1 to 16 keys');
    }
    final rootKeys = <String, String>{};
    for (final e in roots.entries) {
      final v = e.value;
      if (!_keyId.hasMatch(e.key) || v is! String) throw _Bad('root key "${e.key}" is invalid');
      rootKeys[e.key] = v;
    }
    try {
      Es256Verifier(rootKeys); // every key must be a valid P-256 point
    } catch (_) {
      throw _Bad('a root key is not a valid P-256 public key');
    }
    final rt = j['runtime'];
    if (rt is! Map<String, Object?> || !rt.keys.toSet().containsAll(_runtimeKeys) || rt.length != _runtimeKeys.length) {
      throw _Bad('"runtime" must have exactly ${_runtimeKeys.join(', ')}');
    }
    final runtime = {for (final k in _runtimeKeys) k: str(rt, k, _version)};
    Set<String> packages(String k) {
      final v = j[k];
      if (v is! List || v.length > 512 || v.any((e) => e is! String || !_pkg.hasMatch(e))) {
        throw _Bad('"$k" must be a list of package names');
      }
      return v.cast<String>().toSet();
    }

    final approvals = j['required_approvals'] ?? 0;
    if (approvals is! int || approvals < 0 || approvals > 16) throw _Bad('"required_approvals" is invalid');
    final releaseVersion = j['release_version'];
    if (releaseVersion != null && (releaseVersion is! String || !_version.hasMatch(releaseVersion))) {
      throw _Bad('"release_version" is invalid');
    }
    final channel = j['channel'] ?? 'production';
    if (channel is! String || !_name.hasMatch(channel)) throw _Bad('"channel" is invalid');
    return ConfigResult._(
      FlutterOtaConfig._(
        appId: str(j, 'app_id', _uuid),
        serverUrl: server! as String,
        releaseId: str(j, 'release_id', _uuid),
        environment: str(j, 'environment', _name),
        rootKeys: rootKeys,
        toolchainId: str(j, 'toolchain_id', _sha),
        runtime: runtime,
        interfaceSha256: str(j, 'interface_sha256', _sha),
        hostPackages: packages('host_packages'),
        entryContract: supportedEntryContract,
        releaseVersion: releaseVersion as String?,
        channel: channel,
        requiredApprovals: approvals,
        hostOwnedPackages: {
          ...alwaysHostOwned,
          if (j.containsKey('host_owned_packages')) ...packages('host_owned_packages'),
        },
      ),
      null,
      warnings,
    );
  }

  /// Encodes [json] the way the CLI does: base64url of the canonical JSON. For tools and tests.
  static String encode(Map<String, Object?> json) => base64Url.encode(canonicalJson(json));
}

/// Result of [FlutterOtaConfig.parse]: a config, or the reason OTA is disabled.
class ConfigResult {
  const ConfigResult._(this.config, this.disabledReason, [this.warnings = const []]);
  const ConfigResult.disabled(String reason) : this._(null, reason);

  final FlutterOtaConfig? config;
  final String? disabledReason;
  final List<String> warnings;
}

class _Bad implements Exception {
  _Bad(this.why);
  final String why;
}
