// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Usage: dart run bin/verify.dart <host.json> <patch.otp>...
// host.json: {app_id, release_id, baseline_libapp_sha256, runtime, interface_sha256,
//             host_packages, host_owned_packages, entry_contract, toolchain_id, roots,
//             environment, now}
// Prints one line per file: "OK <patch_id> <sequence>" or "REJECT <code> <reason>".

import 'dart:convert';
import 'dart:io';

import 'package:patch_security/patch_security.dart';

void main(List<String> args) {
  final h =
      jsonDecode(File(args.first).readAsStringSync()) as Map<String, Object?>;
  final host = HostIdentity(
    appId: h['app_id']! as String,
    releaseId: h['release_id']! as String,
    baselineLibappSha256: h['baseline_libapp_sha256']! as String,
    runtime: (h['runtime']! as Map).cast<String, String>(),
    interfaceSha256: h['interface_sha256']! as String,
    hostPackages: (h['host_packages']! as List).cast<String>().toSet(),
    hostOwnedPackages: (h['host_owned_packages']! as List)
        .cast<String>()
        .toSet(),
    entryContract: h['entry_contract']! as int,
    toolchainId: h['toolchain_id']! as String,
  );
  final trust = CertificateTrust(
    roots: Es256Verifier((h['roots']! as Map).cast<String, String>()),
    environment: h['environment']! as String,
  );
  for (final path in args.skip(1)) {
    try {
      final v = verifyPatch(
        File(path).readAsBytesSync(),
        host: host,
        keys: Es256Verifier({}),
        state: DeviceSecurityState(),
        now: DateTime.parse(h['now']! as String),
        trust: trust,
      );
      print('OK ${v.manifest.patchId} ${v.manifest.sequence}');
    } on PatchRejected catch (e) {
      print('REJECT ${e.code} ${e.reason}');
    }
  }
}
