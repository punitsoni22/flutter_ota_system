// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Loads the developer's local patch-signing key.
//
// Keys are created and stored by `flutter_ota keys` (lib/src/keys/key_store.dart, AppKeyStore):
//
//   <config dir>/keys/<app_id>/signers/<key_id>.key        signer private key (0600, PRIVATE)
//   <config dir>/keys/<app_id>/signers/<key_id>.pub
//   <config dir>/keys/<app_id>/signers/<key_id>.cert.json  root-signed certificate
//
// This file only selects and checks the signer for one patch. The private key is read to sign;
// it is never printed, logged, copied into a project or sent to a server.

import 'dart:io';

import '../errors.dart';
import '../keys/key_store.dart';
import '../toolchain/es256.dart';
import 'certificate.dart';

/// A signer ready to sign: key pair plus certificate.
class LocalSigner {
  LocalSigner(this.keyId, this.keyPair, this.certificate);
  final String keyId;
  final Es256KeyPair keyPair;
  final KeyCertificate certificate;
}

int? _mode(String path) {
  final s = FileStat.statSync(path);
  return s.type == FileSystemEntityType.notFound ? null : s.mode & 0x1ff;
}

/// Loads the newest signer of [appId] certified for [environment] and valid at [now], and checks
/// it as the device will: certificate for this app, environment and key, signer role, valid now,
/// and (when [rootPublicKeys] is given: the roots compiled into the release) signed by one of
/// those roots. Every failure is a [CliException] that says what to do.
LocalSigner loadLocalSigner(
  Map<String, String> env, {
  required String appId,
  required String environment,
  required DateTime now,
  Map<String, String>? rootPublicKeys,
}) {
  final store = AppKeyStore.forApp(env, appId);
  final s = store.activeSigner(environment, now);
  if (s == null) {
    final others = store.signers().map((x) => '${x.keyId} (${x.environment}, until ${x.body['not_after']})').toList();
    throw CliException(
      'No certified patch-signing key for app $appId in the $environment environment that is valid now.\n'
      '${others.isEmpty ? 'No signer keys found in ${store.signersDir}.' : 'Found: ${others.join(', ')}.'}\n'
      'Create one with `flutter_ota keys init` (or ask the holder of the app root key for a signer '
      'certificate). Keys stay in ${store.dir}, never in the project.',
    );
  }
  final mode = _mode(s.privateKeyPath);
  if (mode == null) throw CliException('The private key ${s.privateKeyPath} is missing.');
  if (mode & 0x3f != 0) {
    throw CliException(
      'The private key ${s.privateKeyPath} can be read by other users (mode ${mode.toRadixString(8)}). '
      'Fix it with:  chmod 600 ${s.privateKeyPath}',
    );
  }
  final cert = KeyCertificate.parse(s.certificate);
  final Es256KeyPair kp;
  try {
    kp = s.loadPrivate();
  } on FormatException {
    throw CliException('The private key file ${s.privateKeyPath} is damaged.');
  }
  if (cert.keyId != s.keyId) throw CliException('The certificate of ${s.keyId} names another key (${cert.keyId}).');
  final problems = cert.problemsForSigning(
    appId: appId,
    environment: environment,
    publicKey: kp.publicKeyBase64,
    now: now,
    rootPublicKeys: rootPublicKeys,
  );
  if (problems.isNotEmpty) {
    throw CliException(
      'The signing key ${s.keyId} cannot sign patches for this release:\n'
      '${problems.map((x) => '  - $x').join('\n')}\n'
      'A device would refuse such a patch, so nothing was signed.',
    );
  }
  return LocalSigner(s.keyId, kp, cert);
}
