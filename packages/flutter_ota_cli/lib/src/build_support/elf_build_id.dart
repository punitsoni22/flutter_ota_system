// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Reads the GNU build ID of a 64-bit little-endian ELF file (for example the arm64
/// `libflutter.so`).
///
/// The build ID is a hash the linker writes into a `PT_NOTE` segment. Stripping debug symbols
/// (which the Android Gradle plugin does when it packages an APK or AAB) keeps it, so it
/// identifies one engine build whether the library is stripped or not.
library;

import 'dart:typed_data';

const _ptNote = 4;
const _ntGnuBuildId = 3;

/// The GNU build ID as lowercase hex, or `null` when [bytes] is not a 64-bit little-endian ELF
/// file or has no GNU build-ID note.
String? elfGnuBuildId(List<int> bytes) {
  final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (b.length < 64 || b[0] != 0x7f || b[1] != 0x45 || b[2] != 0x4c || b[3] != 0x46) return null;
  if (b[4] != 2 || b[5] != 1) return null; // ELFCLASS64, little endian
  final d = ByteData.sublistView(b);
  final phoff = d.getUint64(0x20, Endian.little);
  final phentsize = d.getUint16(0x36, Endian.little);
  final phnum = d.getUint16(0x38, Endian.little);
  if (phentsize < 56) return null;
  for (var i = 0; i < phnum; i++) {
    final ph = phoff + i * phentsize;
    if (ph + 56 > b.length) return null;
    if (d.getUint32(ph, Endian.little) != _ptNote) continue;
    final off = d.getUint64(ph + 8, Endian.little);
    final size = d.getUint64(ph + 32, Endian.little);
    if (off + size > b.length) continue;
    final id = _buildIdInNotes(d, off, off + size);
    if (id != null) return id;
  }
  return null;
}

String? _buildIdInNotes(ByteData d, int start, int end) {
  int align4(int v) => (v + 3) & ~3;
  var pos = start;
  while (pos + 12 <= end) {
    final namesz = d.getUint32(pos, Endian.little);
    final descsz = d.getUint32(pos + 4, Endian.little);
    final type = d.getUint32(pos + 8, Endian.little);
    final nameStart = pos + 12;
    final descStart = nameStart + align4(namesz);
    final next = descStart + align4(descsz);
    if (next > end || namesz > 64 || descsz > 1024) return null;
    final isGnu = namesz == 4 &&
        d.getUint8(nameStart) == 0x47 && // G
        d.getUint8(nameStart + 1) == 0x4e && // N
        d.getUint8(nameStart + 2) == 0x55 && // U
        d.getUint8(nameStart + 3) == 0;
    if (isGnu && type == _ntGnuBuildId && descsz > 0) {
      final sb = StringBuffer();
      for (var i = 0; i < descsz; i++) {
        sb.write(d.getUint8(descStart + i).toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    }
    pos = next;
  }
  return null;
}
