// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Patch container OTAPRT02 (format name `dbc-v1`, docs/architecture/phase-4-backend-protocol.md):
//
//   "OTAPRT02" | u32 BE manifest length | manifest (canonical JSON)
//              | u32 BE signature length | signature block (canonical JSON)
//              | module bytes (Dart bytecode)

import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';

const containerMagic = 'OTAPRT02';
const maxContainerBytes = 8 * 1024 * 1024;
const maxManifestBytes = 64 * 1024;
const maxSignatureBytes = 8 * 1024;

class ContainerParts {
  ContainerParts(this.manifest, this.signature, this.module);
  final Uint8List manifest;
  final Uint8List signature;
  final Uint8List module;
}

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

/// Builds a container, enforcing the same limits as the server and the device.
Uint8List buildContainer(Uint8List manifest, Uint8List signature, Uint8List module) {
  if (manifest.isEmpty || manifest.length > maxManifestBytes) {
    throw CliException('The patch manifest is ${manifest.length} bytes (limit $maxManifestBytes).');
  }
  if (signature.isEmpty || signature.length > maxSignatureBytes) {
    throw CliException('The signature block is ${signature.length} bytes (limit $maxSignatureBytes).');
  }
  final total = 16 + manifest.length + signature.length + module.length;
  if (total > maxContainerBytes) {
    throw CliException(
      'The patch is $total bytes; the limit is $maxContainerBytes bytes (8 MiB). Patch fewer features at once.',
    );
  }
  return (BytesBuilder(copy: false)
        ..add(ascii.encode(containerMagic))
        ..add(_u32(manifest.length))
        ..add(manifest)
        ..add(_u32(signature.length))
        ..add(signature)
        ..add(module))
      .toBytes();
}

/// Splits a container (bounds-checked). Throws [FormatException].
ContainerParts splitContainer(Uint8List file) {
  if (file.length > maxContainerBytes) throw const FormatException('too_large');
  if (file.length < 16 || ascii.decode(file.sublist(0, 8), allowInvalid: true) != containerMagic) {
    throw const FormatException('bad_magic');
  }
  final view = ByteData.sublistView(file);
  final mLen = view.getUint32(8);
  if (mLen == 0 || mLen > maxManifestBytes || 12 + mLen + 4 > file.length) {
    throw const FormatException('bad_manifest_length');
  }
  final sLen = view.getUint32(12 + mLen);
  final moduleStart = 16 + mLen + sLen;
  if (sLen == 0 || sLen > maxSignatureBytes || moduleStart > file.length) {
    throw const FormatException('bad_signature_length');
  }
  return ContainerParts(
    Uint8List.sublistView(file, 12, 12 + mLen),
    Uint8List.sublistView(file, 16 + mLen, moduleStart),
    Uint8List.sublistView(file, moduleStart),
  );
}
