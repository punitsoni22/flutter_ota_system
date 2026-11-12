// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

/// Patch container v2 (Phase 3 prototype):
///
///   "OTAPRT02" | u32 BE manifest length | manifest (canonical JSON)
///              | u32 BE signature length | signature (canonical JSON {alg, key_id, sig})
///              | module bytes (Dart bytecode)
///
/// The signature covers the manifest bytes exactly; the manifest carries the module's SHA-256 and
/// size, so the signature covers the module too.
const containerMagic = 'OTAPRT02';

/// Hard limits, checked before anything is decoded (bounded parsing).
const maxContainerBytes = 8 * 1024 * 1024;
const maxManifestBytes = 64 * 1024;
// Phase 3C: the signature block can carry a key certificate and approvals.
const maxSignatureBytes = 8 * 1024;

class ContainerParts {
  ContainerParts(this.manifestBytes, this.signatureBytes, this.module);
  final Uint8List manifestBytes;
  final Uint8List signatureBytes;
  final Uint8List module;
}

class PatchRejected implements Exception {
  PatchRejected(this.code, this.reason);

  /// Stable machine-readable code (used by tests and logs).
  final String code;
  final String reason;
  @override
  String toString() => '$code: $reason';
}

ContainerParts splitContainer(Uint8List file) {
  if (file.length > maxContainerBytes) throw PatchRejected('too_large', 'patch file exceeds $maxContainerBytes bytes');
  if (file.length < 16) throw PatchRejected('truncated', 'patch file is shorter than the container header');
  if (ascii.decode(file.sublist(0, 8), allowInvalid: true) != containerMagic) {
    throw PatchRejected('bad_magic', 'not a v2 patch container');
  }
  final view = ByteData.sublistView(file);
  final mLen = view.getUint32(8);
  if (mLen == 0 || mLen > maxManifestBytes) throw PatchRejected('bad_manifest_length', 'manifest length $mLen out of range');
  if (12 + mLen + 4 > file.length) throw PatchRejected('truncated', 'manifest extends past the end of the file');
  final sLen = view.getUint32(12 + mLen);
  if (sLen == 0 || sLen > maxSignatureBytes) throw PatchRejected('bad_signature_length', 'signature length $sLen out of range');
  final moduleStart = 12 + mLen + 4 + sLen;
  if (moduleStart > file.length) throw PatchRejected('truncated', 'signature extends past the end of the file');
  return ContainerParts(
    Uint8List.sublistView(file, 12, 12 + mLen),
    Uint8List.sublistView(file, 16 + mLen, moduleStart),
    Uint8List.sublistView(file, moduleStart),
  );
}

Uint8List buildContainer(Uint8List manifest, Uint8List signature, Uint8List module) {
  final b = BytesBuilder(copy: false)
    ..add(ascii.encode(containerMagic))
    ..add((ByteData(4)..setUint32(0, manifest.length)).buffer.asUint8List())
    ..add(manifest)
    ..add((ByteData(4)..setUint32(0, signature.length)).buffer.asUint8List())
    ..add(signature)
    ..add(module);
  return b.toBytes();
}
