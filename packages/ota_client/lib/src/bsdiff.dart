// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
//
// The patch-apply loop implements the bsdiff 4 / bspatch algorithm by Colin Percival,
// distributed under the following licence:
//
// Copyright 2003-2005 Colin Percival
// All rights reserved
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted providing that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
// IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

import 'dart:io';
import 'dart:typed_data';

/// Applies an `OTADIF01` patch: bsdiff's control/diff/extra blocks, each zlib-compressed.
///
/// Layout (all integers little-endian int64):
///   "OTADIF01" | new size | control bytes | diff bytes | extra bytes | control | diff | extra
/// Control is a list of (add, copy, seek) triples, exactly as in bsdiff 4.
/// The CLI writes this format (`cli/otadiff.py`); zlib keeps it decodable with dart:io alone.
Uint8List applyOtaDiff(Uint8List old, Uint8List patch) {
  const magic = 'OTADIF01';
  if (patch.length < 40 || String.fromCharCodes(patch.sublist(0, 8)) != magic) {
    throw const FormatException('not an OTADIF01 patch');
  }
  final header = ByteData.sublistView(patch, 8, 40);
  final newSize = header.getInt64(0, Endian.little);
  final controlLen = header.getInt64(8, Endian.little);
  final diffLen = header.getInt64(16, Endian.little);
  final extraLen = header.getInt64(24, Endian.little);
  if (newSize < 0 ||
      controlLen < 0 ||
      diffLen < 0 ||
      extraLen < 0 ||
      40 + controlLen + diffLen + extraLen != patch.length) {
    throw const FormatException('corrupt OTADIF01 header');
  }

  Uint8List inflate(int from, int len) =>
      Uint8List.fromList(ZLibCodec().decode(Uint8List.sublistView(patch, from, from + len)));
  final control = inflate(40, controlLen);
  final diff = inflate(40 + controlLen, diffLen);
  final extra = inflate(40 + controlLen + diffLen, extraLen);
  if (control.length % 24 != 0) throw const FormatException('corrupt OTADIF01 control block');
  final ctrl = ByteData.sublistView(control);

  final out = Uint8List(newSize);
  var newPos = 0, oldPos = 0, diffPos = 0, extraPos = 0;
  for (var i = 0; i < control.length; i += 24) {
    final add = ctrl.getInt64(i, Endian.little);
    final copy = ctrl.getInt64(i + 8, Endian.little);
    final seek = ctrl.getInt64(i + 16, Endian.little);
    if (add < 0 ||
        copy < 0 ||
        newPos + add + copy > newSize ||
        diffPos + add > diff.length ||
        extraPos + copy > extra.length) {
      throw const FormatException('OTADIF01 patch out of bounds');
    }
    for (var j = 0; j < add; j++) {
      final o = oldPos + j;
      out[newPos + j] = (diff[diffPos + j] + (o >= 0 && o < old.length ? old[o] : 0)) & 0xff;
    }
    newPos += add;
    oldPos += add;
    diffPos += add;
    out.setRange(newPos, newPos + copy, extra, extraPos);
    newPos += copy;
    extraPos += copy;
    oldPos += seek;
  }
  if (newPos != newSize) throw const FormatException('OTADIF01 patch is truncated');
  return out;
}
