// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../errors.dart';
import '../toolchain/es256.dart';
import '../toolchain/transport.dart';

/// Settings a user may store (never private keys or admin secrets).
const configKeys = {
  'server-url': 'OTA server URL (https://, or http:// to localhost for local testing)',
  'toolchain-index-url': 'URL of a signed toolchain index (https://, file:// or http://localhost)',
};

/// Environment variables that override the config file.
const configEnv = {'server-url': 'FLUTTER_OTA_SERVER_URL', 'toolchain-index-url': 'FLUTTER_OTA_TOOLCHAIN_INDEX'};

/// Where a resolved setting came from.
enum ConfigSource { flag, environment, file, builtIn, unset }

class ConfigValue {
  const ConfigValue(this.value, this.source);
  final String? value;
  final ConfigSource source;
}

/// The user's CLI config: `$XDG_CONFIG_HOME/flutter_ota/config.yaml` (default
/// `~/.config/flutter_ota/config.yaml`), file mode 0600. `FLUTTER_OTA_CONFIG_DIR` overrides the
/// directory (tests, CI).
class UserConfig {
  UserConfig._(this.path, this.values, this.toolchainKeys);

  static String pathFor(Map<String, String> env) {
    final dirOverride = env['FLUTTER_OTA_CONFIG_DIR'];
    if (dirOverride != null && dirOverride.isNotEmpty) return p.join(dirOverride, 'config.yaml');
    final xdg = env['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : p.join(env['HOME'] ?? '.', '.config');
    return p.join(base, 'flutter_ota', 'config.yaml');
  }

  static UserConfig load(Map<String, String> env) {
    final path = pathFor(env);
    final f = File(path);
    final values = <String, String>{};
    final keys = <String, String>{};
    if (f.existsSync()) {
      final Object? y;
      try {
        y = loadYaml(f.readAsStringSync());
      } on YamlException catch (e) {
        throw CliException('$path is not valid YAML: ${e.message}');
      }
      if (y != null && y is! YamlMap) throw CliException('$path must be a YAML map.');
      if (y is YamlMap) {
        for (final k in configKeys.keys) {
          final v = y[k];
          if (v is String) values[k] = v;
        }
        final tk = y['toolchain-trusted-keys'];
        if (tk is YamlMap) {
          tk.forEach((k, v) {
            if (k is String && v is String) keys[k] = v;
          });
        }
      }
    }
    return UserConfig._(path, values, keys);
  }

  final String path;
  final Map<String, String> values;

  /// Extra toolchain-signing public keys (key id -> base64) trusted by this user.
  final Map<String, String> toolchainKeys;

  /// Resolves [key] with precedence: command-line flag > environment variable > config file >
  /// built-in default.
  ConfigValue resolve(String key, Map<String, String> env, {String? flag, String? builtIn}) {
    if (flag != null && flag.isNotEmpty) return ConfigValue(flag, ConfigSource.flag);
    final envName = configEnv[key];
    final e = envName == null ? null : env[envName];
    if (e != null && e.isNotEmpty) return ConfigValue(e, ConfigSource.environment);
    final v = values[key];
    if (v != null) return ConfigValue(v, ConfigSource.file);
    if (builtIn != null) return ConfigValue(builtIn, ConfigSource.builtIn);
    return const ConfigValue(null, ConfigSource.unset);
  }

  void set(String key, String value) {
    if (!configKeys.containsKey(key)) {
      throw CliException('Unknown setting "$key". Known settings: ${configKeys.keys.join(', ')}.');
    }
    values[key] = validateSetting(key, value);
    _save();
  }

  void unset(String key) {
    if (values.remove(key) != null) _save();
  }

  void addToolchainKey(String keyId, String publicKeyB64) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(keyId)) throw CliException('Invalid key id "$keyId".');
    try {
      parseEs256PublicKey(publicKeyB64);
    } on FormatException {
      throw CliException('Not a valid ES256 public key (expected base64 of an uncompressed P-256 point).');
    }
    if (publicKeyB64.contains('PRIVATE')) throw CliException('That looks like a private key. Never share it.');
    toolchainKeys[keyId] = publicKeyB64.trim();
    _save();
  }

  bool removeToolchainKey(String keyId) {
    final removed = toolchainKeys.remove(keyId) != null;
    if (removed) _save();
    return removed;
  }

  void _save() {
    final buf = StringBuffer(
      '# flutter_ota user settings. Written by `flutter_ota config`.\n'
      '# Never put private keys or admin secrets here.\n',
    );
    for (final k in configKeys.keys) {
      final v = values[k];
      if (v != null) buf.writeln('$k: ${jsonEncode(v)}');
    }
    if (toolchainKeys.isNotEmpty) {
      buf.writeln('toolchain-trusted-keys:');
      for (final k in (toolchainKeys.keys.toList()..sort())) {
        buf.writeln('  ${jsonEncode(k)}: ${jsonEncode(toolchainKeys[k])}');
      }
    }
    final f = File(path);
    f.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(buf.toString(), flush: true);
    Process.runSync('chmod', ['0600', tmp.path]);
    tmp.renameSync(path);
  }
}

/// Validates a setting value; returns the normalised value.
String validateSetting(String key, String value) {
  final v = value.trim();
  final uri = Uri.tryParse(v);
  switch (key) {
    case 'server-url':
      if (uri == null || !uri.hasAuthority || uri.host.isEmpty) throw CliException('"$v" is not a URL.');
      if (uri.scheme == 'https') return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
      if (uri.scheme == 'http' && isLoopbackHost(uri.host)) return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
      throw CliException('The server URL must use https:// (http:// is allowed only for localhost testing).');
    case 'toolchain-index-url':
      if (uri == null || uri.scheme.isEmpty) throw CliException('"$v" is not a URL.');
      checkUrlAllowed(uri);
      return v;
  }
  return v;
}
