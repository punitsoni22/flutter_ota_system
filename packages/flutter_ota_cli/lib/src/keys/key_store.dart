// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/user_config.dart';
import '../errors.dart';
import '../toolchain/canonical_json.dart';
import '../toolchain/es256.dart';

/// Domain prefix of key certificates (backend protocol §3).
const keyCertificateDomain = 'flutter-ota-system/key-certificate/v1\n';

/// Default trust environment of releases and certificates.
const defaultEnvironment = 'production';

final _keyIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// Checks a trust environment name (same rule as key ids on the server).
String validateEnvironment(String v) {
  if (!_keyIdPattern.hasMatch(v)) {
    throw CliException('"$v" is not a valid environment name (letters, digits, ".", "_", "-").');
  }
  return v;
}

/// A signer key with its root-signed certificate.
class SignerKey {
  SignerKey(this.keyId, this.publicKey, this.certificate, this.privateKeyPath);
  final String keyId;
  final String publicKey;

  /// `{"body": {...}, "root_key_id": ..., "sig": ...}`
  final Map<String, Object?> certificate;
  final String privateKeyPath;

  Map<String, Object?> get body => certificate['body'] as Map<String, Object?>;
  String get environment => body['environment'] as String;
  String get rootKeyId => certificate['root_key_id'] as String;
  int get serial => body['serial'] as int;
  DateTime get notAfter => DateTime.parse(body['not_after'] as String);
  DateTime get notBefore => DateTime.parse(body['not_before'] as String);

  /// Loads the private key (only for signing, on this machine).
  Es256KeyPair loadPrivate() => Es256KeyPair.fromPrivateBase64(File(privateKeyPath).readAsStringSync());
}

/// Local developer keys of one app, outside every project:
///
///     <config dir>/keys/<app_id>/roots/<key_id>.key        ROOT private key (0600; keep offline)
///     <config dir>/keys/<app_id>/roots/<key_id>.pub        root public key (compiled into apps)
///     <config dir>/keys/<app_id>/signers/<key_id>.key      signer private key (0600)
///     <config dir>/keys/<app_id>/signers/<key_id>.pub
///     <config dir>/keys/<app_id>/signers/<key_id>.cert.json  root-signed certificate (public)
///
/// `<config dir>` is `~/.config/flutter_ota` (or `$XDG_CONFIG_HOME/flutter_ota`,
/// `$FLUTTER_OTA_CONFIG_DIR`). Private keys never leave this folder: the server only receives
/// public keys and certificates.
class AppKeyStore {
  AppKeyStore(this.dir, this.appId);

  factory AppKeyStore.forApp(Map<String, String> env, String appId) {
    final override = env['FLUTTER_OTA_KEYS_DIR'];
    final base = (override != null && override.isNotEmpty)
        ? override
        : p.join(p.dirname(UserConfig.pathFor(env)), 'keys');
    return AppKeyStore(p.join(base, appId), appId);
  }

  final String dir;
  final String appId;

  String get rootsDir => p.join(dir, 'roots');
  String get signersDir => p.join(dir, 'signers');

  /// Root public keys found locally: key id -> base64 uncompressed point.
  Map<String, String> rootPublicKeys() => _publicKeys(rootsDir);

  bool hasRootPrivateKey(String keyId) => File(p.join(rootsDir, '$keyId.key')).existsSync();

  /// Signer keys that have a certificate, newest certificate first.
  List<SignerKey> signers() {
    final d = Directory(signersDir);
    if (!d.existsSync()) return [];
    final out = <SignerKey>[];
    for (final f in d.listSync().whereType<File>()) {
      if (!f.path.endsWith('.cert.json')) continue;
      final keyId = p.basename(f.path).replaceAll('.cert.json', '');
      final pub = File(p.join(signersDir, '$keyId.pub'));
      final key = p.join(signersDir, '$keyId.key');
      if (!pub.existsSync() || !File(key).existsSync()) continue;
      try {
        final cert = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        out.add(SignerKey(keyId, pub.readAsStringSync().trim(), cert, key));
      } on Object {
        continue; // unreadable certificate: ignored
      }
    }
    out.sort((a, b) => b.notBefore.compareTo(a.notBefore));
    return out;
  }

  /// The newest signer certified for [environment] and valid at [now], or null.
  SignerKey? activeSigner(String environment, DateTime now) {
    for (final s in signers()) {
      if (s.environment == environment && !now.isBefore(s.notBefore) && now.isBefore(s.notAfter)) return s;
    }
    return null;
  }

  /// Generates a new root key pair; returns its key id.
  String createRoot() {
    final kp = Es256KeyPair.generate();
    final id = 'root-${_fingerprint(kp.publicKeyBase64)}';
    _writeKeyPair(rootsDir, id, kp);
    return id;
  }

  /// Generates a signer key and a certificate signed by the local root [rootKeyId].
  SignerKey createSigner({
    required String rootKeyId,
    required String environment,
    required Duration validity,
    DateTime? now,
  }) {
    final rootFile = File(p.join(rootsDir, '$rootKeyId.key'));
    if (!rootFile.existsSync()) {
      throw CliException(
        'The root private key $rootKeyId is not on this machine (${rootFile.path}).\n'
        'Certificates can only be issued where the root key is kept.',
      );
    }
    final root = Es256KeyPair.fromPrivateBase64(rootFile.readAsStringSync());
    final kp = Es256KeyPair.generate();
    final id = 'signer-${_fingerprint(kp.publicKeyBase64)}';
    final start = (now ?? DateTime.now()).toUtc().subtract(const Duration(minutes: 5));
    final body = <String, Object?>{
      'type': 'key_cert',
      'app_id': appId,
      'environment': validateEnvironment(environment),
      'key_id': id,
      'public_key': kp.publicKeyBase64,
      'roles': ['signer'],
      'serial': _serial(),
      'not_before': _utc(start),
      'not_after': _utc(start.add(validity)),
    };
    final sig = root.sign(domainMessage(keyCertificateDomain, canonicalJson(body)));
    final cert = <String, Object?>{'body': body, 'root_key_id': rootKeyId, 'sig': sig};
    _writeKeyPair(signersDir, id, kp);
    final certFile = File(p.join(signersDir, '$id.cert.json'));
    certFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(cert)}\n');
    return SignerKey(id, kp.publicKeyBase64, cert, p.join(signersDir, '$id.key'));
  }

  Map<String, String> _publicKeys(String d) {
    final dir = Directory(d);
    if (!dir.existsSync()) return {};
    final out = <String, String>{};
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.pub')) continue;
      out[p.basenameWithoutExtension(f.path)] = f.readAsStringSync().trim();
    }
    return Map.fromEntries(out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  void _writeKeyPair(String d, String id, Es256KeyPair kp) {
    _ensureDir(d);
    final key = File(p.join(d, '$id.key'));
    // Create the file empty with mode 0600 before writing the secret into it.
    key.writeAsStringSync('');
    Process.runSync('chmod', ['0600', key.path]);
    key.writeAsStringSync('${kp.privateKeyBase64}\n', flush: true);
    File(p.join(d, '$id.pub')).writeAsStringSync('${kp.publicKeyBase64}\n');
  }

  void _ensureDir(String d) {
    for (final x in [p.dirname(dir), dir, d]) {
      final dd = Directory(x);
      if (!dd.existsSync()) dd.createSync(recursive: true);
      Process.runSync('chmod', ['0700', x]);
    }
  }
}

String _fingerprint(String publicKeyB64) => sha256.convert(base64.decode(publicKeyB64)).toString().substring(0, 12);

int _serial() {
  final r = Random.secure();
  // 48 random bits, never 0 (the server needs 1 <= serial < 2^63).
  return (r.nextInt(1 << 24) << 24 | r.nextInt(1 << 24)) + 1;
}

String _utc(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}
