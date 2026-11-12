// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Magic number at the start of every Dart kernel component (`.dill`).
const kernelMagic = 0x90ABCDEF;

/// Lists the import URIs of every library stored in a Dart kernel file (`.dill`).
///
/// Only the small parts of the binary format that are needed are read (see `pkg/kernel/binary.md`
/// in the Dart SDK):
///
/// - the component index at the end of each component (fixed 32-bit fields, library offsets);
/// - the canonical-name table and the string table;
/// - the start of each library header (`flags`, language version, canonical name).
///
/// A library's canonical name is its import URI (`package:...` or `dart:...`). Libraries that are
/// only referenced (for example the platform when compiled with `--no-link-platform`) are not
/// listed. Concatenated components are supported. Throws [FormatException] on anything unexpected.
List<String> kernelLibraryUris(Uint8List bytes) {
  final out = <String>{};
  var end = bytes.length;
  while (end > 0) {
    if (end < 8 * 4) throw const FormatException('kernel file too short');
    final size = _u32(bytes, end - 4);
    final start = end - size;
    if (size < 8 * 4 || start < 0) throw const FormatException('bad component size');
    if (_u32(bytes, start) != kernelMagic) throw const FormatException('not a Dart kernel file (bad magic)');
    out.addAll(_component(bytes, start, end));
    end = start;
  }
  return out.toList()..sort();
}

/// [kernelLibraryUris] of a file.
List<String> kernelLibraryUrisOfFile(String path) => kernelLibraryUris(File(path).readAsBytesSync());

/// Number of fixed 32-bit fields in the component index before the library offsets
/// (binaryOffsetForSourceTable ... mainMethodReference).
const _fixedIndexFields = 9;

List<String> _component(Uint8List b, int start, int end) {
  final libraryCount = _u32(b, end - 8);
  final offsetsStart = end - 8 - 4 * (libraryCount + 1);
  final fixedStart = offsetsStart - 4 * _fixedIndexFields;
  if (libraryCount > 1000000 || fixedStart < start) throw const FormatException('bad component index');
  final canonicalNamesOffset = _u32(b, fixedStart + 4 * 3);
  final stringTableOffset = _u32(b, fixedStart + 4 * 6);

  final strings = _readStringTable(b, start + stringTableOffset, end);
  final names = _readCanonicalNames(b, start + canonicalNamesOffset, end);

  final libs = <String>[];
  for (var i = 0; i < libraryCount; i++) {
    final off = start + _u32(b, offsetsStart + 4 * i);
    if (off < start || off >= end) throw const FormatException('bad library offset');
    final r = _Reader(b, off + 1, end); // skip flags
    r.uint(); // language version major
    r.uint(); // language version minor
    final ref = r.uint(); // canonical name reference (index + 1; 0 = none)
    if (ref == 0 || ref > names.length) throw const FormatException('library without canonical name');
    final (parent, nameIndex) = names[ref - 1];
    if (parent != 0) throw const FormatException('library canonical name is not top-level');
    if (nameIndex >= strings.length) throw const FormatException('bad string reference');
    libs.add(strings[nameIndex]);
  }
  return libs;
}

List<String> _readStringTable(Uint8List b, int at, int end) {
  final r = _Reader(b, at, end);
  final count = r.uint();
  final ends = List<int>.generate(count, (_) => r.uint());
  final base = r.pos;
  final out = <String>[];
  var prev = 0;
  for (final e in ends) {
    if (e < prev || base + e > end) throw const FormatException('bad string table');
    out.add(utf8.decode(Uint8List.sublistView(b, base + prev, base + e)));
    prev = e;
  }
  return out;
}

List<(int, int)> _readCanonicalNames(Uint8List b, int at, int end) {
  final r = _Reader(b, at, end);
  final count = r.uint();
  return List<(int, int)>.generate(count, (_) => (r.uint(), r.uint()));
}

int _u32(Uint8List b, int at) {
  if (at < 0 || at + 4 > b.length) throw const FormatException('read past end of kernel file');
  return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

class _Reader {
  _Reader(this.b, this.pos, this.end);
  final Uint8List b;
  int pos;
  final int end;

  int _byte() {
    if (pos >= end) throw const FormatException('read past end of kernel component');
    return b[pos++];
  }

  /// Kernel `UInt`: 7, 14 or 30 bits, big-endian, tagged by the top bits of the first byte.
  int uint() {
    final first = _byte();
    if (first & 0x80 == 0) return first;
    if (first & 0x40 == 0) return ((first & 0x3f) << 8) | _byte();
    return ((first & 0x3f) << 24) | (_byte() << 16) | (_byte() << 8) | _byte();
  }
}
