// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/src/build_support/elf_build_id.dart';
import 'package:test/test.dart';

import 'elf_fixture.dart';

void main() {
  test('reads the GNU build ID of a 64-bit ELF file', () {
    expect(elfGnuBuildId(fakeElf(otaEngineBuildId)), otaEngineBuildId);
  });

  test('stripped and unstripped variants of one build have the same ID; stock differs', () {
    expect(elfGnuBuildId(fakeElf(otaEngineBuildId, padding: 100000)), otaEngineBuildId);
    expect(elfGnuBuildId(fakeElf(stockEngineBuildId)), isNot(otaEngineBuildId));
  });

  test('non-ELF, 32-bit, truncated and note-less input give null (never throw)', () {
    expect(elfGnuBuildId('OUR OTA libflutter.so'.codeUnits), isNull);
    final elf = fakeElf(otaEngineBuildId);
    expect(elfGnuBuildId([...elf.take(4), 1, ...elf.skip(5)]), isNull); // ELFCLASS32
    for (final n in [0, 10, 63, 64, 100, elf.length - 1]) {
      expect(elfGnuBuildId(elf.sublist(0, n)), isNull, reason: 'truncated to $n');
    }
    final noNote = [...elf]..[120 + 8] = 9; // note type != NT_GNU_BUILD_ID
    expect(elfGnuBuildId(noNote), isNull);
  });

  test('real engine libraries (opt-in: FLUTTER_OTA_LAB_TESTS=1)', () {
    final out = '${Platform.environment['HOME']}/.cache/flutter-ota-lab/engine/engine/src/out/android_release_arm64';
    final a = File('$out/libflutter.so'), b = File('$out/lib.stripped/libflutter.so');
    final ida = elfGnuBuildId(a.readAsBytesSync()), idb = elfGnuBuildId(b.readAsBytesSync());
    expect(ida, isNotNull);
    expect(ida, idb);
  }, skip: Platform.environment['FLUTTER_OTA_LAB_TESTS'] == '1' ? false : 'lab test (FLUTTER_OTA_LAB_TESTS=1)');
}
