// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import '../errors.dart';
import '../patch/container.dart';
import '../patch/manifest.dart';
import '../toolchain/canonical_json.dart';
import '../toolchain/es256.dart';
import 'certificate.dart';
import 'key_store.dart';

/// Signs [manifest] with [signer] and returns the OTAPRT02 container with [module].
///
/// The manifest is validated against the v2 schema first, the signature block is
/// `{"alg": "ES256", "cert": <certificate>, "key_id": ..., "sig": <raw r||s, base64>}` over
/// `"flutter-ota-system/patch-manifest/v2\n" + manifest bytes`, and the signature is verified
/// again with the certified public key before the container is returned.
Uint8List signPatch(Map<String, Object?> manifest, Uint8List module, LocalSigner signer) {
  validatePatchManifest(manifest);
  if (manifest['key_id'] != signer.keyId) throw CliException('The manifest key_id differs from the signer key.');
  final body = canonicalJson(manifest);
  final message = domainMessage(manifestDomain, body);
  final sig = signer.keyPair.sign(message);
  if (!es256Verify(parseEs256PublicKey(signer.certificate.publicKey), message, sig)) {
    throw CliException('The new signature does not verify with the certified key; nothing was written.');
  }
  final block = canonicalJson({'alg': 'ES256', 'cert': signer.certificate.json, 'key_id': signer.keyId, 'sig': sig});
  return buildContainer(body, block, module);
}
