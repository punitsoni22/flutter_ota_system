// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

/// One entry of a ZIP central directory.
class ZipEntry {
  ZipEntry(this.name, this.method, this.compressedSize, this.size, this.localHeaderOffset);
  final String name;
  final int method;
  final int compressedSize;
  final int size;
  final int localHeaderOffset;
}

/// Minimal read-only ZIP reader for APK, AAB and JAR files (stored and deflated entries, no
/// ZIP64, no encryption). Throws [FormatException] on anything else.
class ZipReader {
  ZipReader._(this._file, this.entries);

  static ZipReader open(String path) {
    final f = File(path).openSync();
    try {
      return ZipReader._(f, _readCentralDirectory(f));
    } catch (_) {
      f.closeSync();
      rethrow;
    }
  }

  final RandomAccessFile _file;
  final Map<String, ZipEntry> entries;

  void close() => _file.closeSync();

  /// The uncompressed bytes of [name], or null if the archive has no such entry.
  Uint8List? read(String name) {
    final e = entries[name];
    if (e == null) return null;
    _file.setPositionSync(e.localHeaderOffset);
    final h = _file.readSync(30);
    if (h.length != 30 || _u32le(h, 0) != 0x04034b50) throw FormatException('bad local header for $name');
    final dataStart = e.localHeaderOffset + 30 + _u16le(h, 26) + _u16le(h, 28);
    _file.setPositionSync(dataStart);
    final raw = _file.readSync(e.compressedSize);
    if (raw.length != e.compressedSize) throw FormatException('truncated entry $name');
    final Uint8List out;
    switch (e.method) {
      case 0:
        out = raw;
      case 8:
        out = Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      default:
        throw FormatException('unsupported compression method ${e.method} for $name');
    }
    if (out.length != e.size) throw FormatException('size mismatch for $name');
    return out;
  }

  static Map<String, ZipEntry> _readCentralDirectory(RandomAccessFile f) {
    final len = f.lengthSync();
    final tail = len < 65557 ? len : 65557;
    f.setPositionSync(len - tail);
    final buf = f.readSync(tail);
    var eocd = -1;
    for (var i = buf.length - 22; i >= 0; i--) {
      if (_u32le(buf, i) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('not a ZIP file (no end of central directory)');
    final count = _u16le(buf, eocd + 10);
    final cdSize = _u32le(buf, eocd + 12);
    final cdOffset = _u32le(buf, eocd + 16);
    if (cdOffset == 0xffffffff || count == 0xffff) throw const FormatException('ZIP64 is not supported');
    if (cdOffset + cdSize > len) throw const FormatException('bad central directory');
    f.setPositionSync(cdOffset);
    final cd = f.readSync(cdSize);
    final out = <String, ZipEntry>{};
    var pos = 0;
    for (var i = 0; i < count; i++) {
      if (pos + 46 > cd.length || _u32le(cd, pos) != 0x02014b50) throw const FormatException('bad central directory');
      final nameLen = _u16le(cd, pos + 28);
      final extraLen = _u16le(cd, pos + 30);
      final commentLen = _u16le(cd, pos + 32);
      if (pos + 46 + nameLen > cd.length) throw const FormatException('bad central directory');
      final name = String.fromCharCodes(cd, pos + 46, pos + 46 + nameLen);
      out[name] = ZipEntry(
        name,
        _u16le(cd, pos + 10),
        _u32le(cd, pos + 20),
        _u32le(cd, pos + 24),
        _u32le(cd, pos + 42),
      );
      pos += 46 + nameLen + extraLen + commentLen;
    }
    return out;
  }
}

/// Reads one entry of the ZIP file at [path] (null when missing).
Uint8List? readZipEntry(String path, String name) {
  final z = ZipReader.open(path);
  try {
    return z.read(name);
  } finally {
    z.close();
  }
}

int _u16le(List<int> b, int at) => b[at] | (b[at + 1] << 8);
int _u32le(List<int> b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
