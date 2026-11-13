// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'canonical.dart';
import 'certs.dart';
import 'container.dart';
import 'manifest.dart';
import 'signature.dart';

/// What this store build is. Compiled into the host at build time.
class HostIdentity {
  const HostIdentity({
    required this.appId,
    required this.releaseId,
    required this.baselineLibappSha256,
    required this.runtime,
    required this.interfaceSha256,
    required this.hostPackages,
    required this.hostOwnedPackages,
    required this.entryContract,
    required this.toolchainId,
  });
  final String appId;
  final String releaseId;

  /// SHA-256 of the libapp.so actually installed (computed on the device, not trusted from input).
  final String baselineLibappSha256;
  final Map<String, String> runtime;
  final String interfaceSha256;
  final Set<String> hostPackages;
  final Set<String> hostOwnedPackages;
  final int entryContract;

  /// SHA-256 id of the toolchain this store build accepts patches from (Phase 3C provenance).
  final String toolchainId;
}

/// Device-side security state (from the private store).
class DeviceSecurityState {
  DeviceSecurityState({
    this.highestSequence = 0,
    Set<String>? blacklist,
    Set<String>? revokedPatchIds,
    Set<String>? revokedKeyIds,
    Set<int>? revokedCertSerials,
    this.activePatchId,
  }) : blacklist = blacklist ?? {},
       revokedPatchIds = revokedPatchIds ?? {},
       revokedKeyIds = revokedKeyIds ?? {},
       revokedCertSerials = revokedCertSerials ?? {};
  int highestSequence;
  final Set<String> blacklist;
  final Set<String> revokedPatchIds;
  final Set<String> revokedKeyIds;
  final Set<int> revokedCertSerials;
  String? activePatchId;
}

class VerifiedPatch {
  VerifiedPatch(this.manifest, this.module);
  final PatchManifest manifest;
  final Uint8List module;
}

/// The ordered verification pipeline (Phase 3 design, part 3.2). The module loader must only ever be
/// given [VerifiedPatch.module] after this returns. Throws [PatchRejected] with a stable code.
///
/// [reinstall] is true when re-checking the already active patch at start-up (its own sequence is
/// then allowed).
VerifiedPatch verifyPatch(
  Uint8List file, {
  required HostIdentity host,
  required Es256Verifier keys,
  required DeviceSecurityState state,
  required DateTime now,
  bool reinstall = false,
  CertificateTrust? trust,
}) {
  Never reject(String code, String reason) => throw PatchRejected(code, reason);

  // 1-2. Container bounds and manifest format (canonical JSON + schema).
  final parts = splitContainer(file);
  final Map<String, Object?> raw;
  try {
    raw = parseCanonicalObject(parts.manifestBytes);
  } on FormatException catch (e) {
    reject('bad_manifest', e.message);
  }
  final m = PatchManifest.validate(raw);

  // 3. Application and release compatibility.
  if (m.appId != host.appId) reject('wrong_app', 'patch is for another application');
  if (m.releaseId != host.releaseId) reject('wrong_release', 'patch is for another store release');
  if (m.baselineLibappSha256 != host.baselineLibappSha256) {
    reject('wrong_baseline', 'patch was built for another libapp.so');
  }

  // 4-5. Signing key and signature.
  final Map<String, Object?> sig;
  try {
    sig = parseCanonicalObject(parts.signatureBytes);
  } on FormatException catch (e) {
    reject('bad_signature_block', e.message);
  }
  if (sig.keys.toSet().difference({'alg', 'key_id', 'sig', 'cert', 'approvals'}).isNotEmpty || sig['alg'] != 'ES256') {
    reject('bad_signature_block', 'unsupported signature block');
  }
  if (sig['key_id'] != m.keyId) reject('key_mismatch', 'signature key id differs from the manifest');
  if (state.revokedKeyIds.contains(m.keyId)) reject('revoked_key', 'signing key ${m.keyId} is revoked');
  if (sig.containsKey('cert')) {
    // Phase 3C: key certified by an application root key (+ approvals).
    if (trust == null) reject('untrusted_root', 'this build has no certificate roots');
    verifyCertifiedSignature(
      sig,
      parts.manifestBytes,
      manifestKeyId: m.keyId,
      trust: trust,
      appId: host.appId,
      now: now.toUtc(),
      revokedSerials: state.revokedCertSerials,
      revokedKeyIds: state.revokedKeyIds,
    );
  } else {
    if (trust != null && trust.requireCertificates) {
      reject('certificate_required', 'this build only accepts certified signing keys');
    }
    if (sig.containsKey('approvals')) reject('bad_signature_block', 'approvals need a certified signer');
    if (!keys.knows(m.keyId)) reject('unknown_key', 'signing key ${m.keyId} is not trusted by this build');
    final signature = sig['sig'];
    if (signature is! String || !keys.verify(m.keyId, signedMessage(manifestDomain, parts.manifestBytes), signature)) {
      reject('bad_signature', 'manifest signature does not verify');
    }
  }

  // 6-7. Module integrity (the manifest is now authentic).
  if (parts.module.isEmpty) reject('missing_module', 'no module bytes');
  if (parts.module.length != m.moduleSize) {
    reject('wrong_size', 'module size ${parts.module.length} != ${m.moduleSize}');
  }
  if (sha256.convert(parts.module).toString() != m.moduleSha256) reject('bad_hash', 'module SHA-256 mismatch');

  // 8. Package and dependency metadata.
  for (final p in m.packages) {
    if (host.hostOwnedPackages.contains(p['name'])) {
      reject('host_owned_package', 'patch carries host-owned package ${p['name']} (requires a store release)');
    }
    if (p['module_name'] == p['name']) reject('unrenamed_package', 'package ${p['name']} is not renamed in the module');
  }
  final missing = (m.hostInterface['host_packages']! as List).cast<String>().where(
    (p) => !host.hostPackages.contains(p),
  );
  if (missing.isNotEmpty) reject('missing_host_package', 'host lacks packages: ${missing.join(', ')}');

  // 9. Runtime compatibility.
  for (final e in host.runtime.entries) {
    if (m.runtime[e.key] != e.value) reject('wrong_runtime', 'runtime ${e.key} ${m.runtime[e.key]} != ${e.value}');
  }
  if (m.hostInterface['sha256'] != host.interfaceSha256) {
    reject('wrong_interface', 'built against another dynamic interface');
  }
  if (m.module['entry_contract'] != host.entryContract) reject('wrong_contract', 'unsupported entry contract');
  // Toolchain provenance: the id must be the hash of the recorded fields AND the id this build
  // accepts. (A signed claim by the patch signer; it does not by itself prove bytecode safety.)
  final tc = m.toolchain;
  final fields = {for (final k in PatchManifest.toolchainFields) k: tc[k]};
  if (sha256.convert(canonicalJson(fields)).toString() != tc['id']) {
    reject('bad_toolchain', 'toolchain id does not match its fields');
  }
  if (tc['id'] != host.toolchainId) reject('wrong_toolchain', 'built with an unsupported toolchain ${tc['id']}');

  // 10. Freshness: blacklist, revocation, replay, expiry.
  if (state.blacklist.contains(m.patchId)) reject('blacklisted', 'patch ${m.patchId} failed before and is blacklisted');
  if (state.revokedPatchIds.contains(m.patchId)) reject('revoked', 'patch ${m.patchId} is revoked');
  final sameActive = reinstall && state.activePatchId == m.patchId;
  if (!sameActive && m.sequence <= state.highestSequence) {
    reject('replay', 'sequence ${m.sequence} is not newer than ${state.highestSequence}');
  }
  final exp = m.expiresAt;
  if (exp != null && !now.toUtc().isBefore(DateTime.parse(exp))) reject('expired', 'patch expired at $exp');
  return VerifiedPatch(m, parts.module);
}

/// Signed revocation list: {release_id, sequence, revoked_patch_ids, revoked_key_ids}.
class RevocationList {
  RevocationList(this.releaseId, this.sequence, this.patchIds, this.keyIds, [this.certSerials = const {}]);
  final String releaseId;
  final int sequence;
  final Set<String> patchIds;
  final Set<String> keyIds;
  final Set<int> certSerials;
}

/// Revocation lists are signed by a directly trusted key or (Phase 3C) by an application root key.
RevocationList verifyRevocations(
  Uint8List file, {
  required HostIdentity host,
  required Es256Verifier keys,
  CertificateTrust? trust,
}) {
  final parts = splitContainer(file);
  final Map<String, Object?> body;
  final Map<String, Object?> sig;
  try {
    body = parseCanonicalObject(parts.manifestBytes);
    sig = parseCanonicalObject(parts.signatureBytes);
  } on FormatException catch (e) {
    throw PatchRejected('bad_revocations', e.message);
  }
  if (body.keys.toSet().difference({
        'type',
        'release_id',
        'sequence',
        'revoked_patch_ids',
        'revoked_key_ids',
        'revoked_cert_serials',
      }).isNotEmpty ||
      body['type'] != 'revocations' ||
      body['release_id'] != host.releaseId ||
      body['sequence'] is! int ||
      body['revoked_patch_ids'] is! List ||
      body['revoked_key_ids'] is! List) {
    throw PatchRejected('bad_revocations', 'invalid revocation list');
  }
  final keyId = sig['key_id'];
  final msg = signedMessage(revocationDomain, parts.manifestBytes);
  final ok =
      keyId is String &&
      sig['alg'] == 'ES256' &&
      sig['sig'] is String &&
      (keys.verify(keyId, msg, sig['sig']! as String) ||
          (trust != null && trust.roots.verify(keyId, msg, sig['sig']! as String)));
  if (!ok) throw PatchRejected('bad_signature', 'revocation list signature does not verify');
  // An absent field (older lists) means none; an explicit null is invalid, as on the server.
  final serials = body.containsKey('revoked_cert_serials') ? body['revoked_cert_serials'] : const <Object?>[];
  if (serials is! List || serials.any((e) => e is! int)) {
    throw PatchRejected('bad_revocations', 'invalid certificate serials');
  }
  final patchIds = body['revoked_patch_ids']! as List, keyIds = body['revoked_key_ids']! as List;
  if (patchIds.any((e) => e is! String) || keyIds.any((e) => e is! String)) {
    throw PatchRejected('bad_revocations', 'revoked ids must be strings');
  }
  return RevocationList(
    host.releaseId,
    body['sequence']! as int,
    patchIds.cast<String>().toSet(),
    keyIds.cast<String>().toSet(),
    serials.cast<int>().toSet(),
  );
}
