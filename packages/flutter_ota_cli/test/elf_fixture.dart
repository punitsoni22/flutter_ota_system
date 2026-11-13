// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

/// A minimal 64-bit little-endian ELF file with one PT_NOTE segment that holds a GNU build-ID note
/// with [buildIdHex], followed by [padding] extra bytes (to make "stripped" and "unstripped"
/// variants of the same build differ in content but not in build ID).
Uint8List fakeElf(String buildIdHex, {int padding = 0}) {
  final id = [for (var i = 0; i < buildIdHex.length; i += 2) int.parse(buildIdHex.substring(i, i + 2), radix: 16)];
  final note = BytesBuilder()
    ..add(_u32(4))
    ..add(_u32(id.length))
    ..add(_u32(3)) // NT_GNU_BUILD_ID
    ..add('GNU'.codeUnits)
    ..addByte(0)
    ..add(id);
  while (note.length % 4 != 0) {
    note.addByte(0);
  }
  const ehsize = 64, phentsize = 56;
  final noteOff = ehsize + phentsize;
  final header = Uint8List(ehsize);
  header.setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
  final h = ByteData.sublistView(header)
    ..setUint64(0x20, ehsize, Endian.little) // e_phoff
    ..setUint16(0x36, phentsize, Endian.little)
    ..setUint16(0x38, 1, Endian.little); // e_phnum
  assert(h.lengthInBytes == ehsize);
  final ph = Uint8List(phentsize);
  ByteData.sublistView(ph)
    ..setUint32(0, 4, Endian.little) // PT_NOTE
    ..setUint64(8, noteOff, Endian.little)
    ..setUint64(32, note.length, Endian.little);
  return (BytesBuilder()
        ..add(header)
        ..add(ph)
        ..add(note.takeBytes())
        ..add(Uint8List(padding)))
      .takeBytes();
}

List<int> _u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

/// Build IDs used by the fixtures.
const otaEngineBuildId = 'cbce549523681a8db4ebd7a27a2876625867f64a';
const stockEngineBuildId = '5c0a941bda2b55bfb68e94a27d703b0b75a24c0c';
