# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Malformed-bytecode corpus for Part 4 (structure-aware + seeded random mutations).

    python3 -I tools/corpus.py <module.bc> <out-dir> [--random N] [--seed S]

Writes one mutated module per case (<NN>_<name>.bc) plus corpus.json describing each mutation.
The DBC3 layout (pinned dart2bytecode, declarations.dart): u32 LE magic 'DBC3', u32 version, then
14 x (u32 numItems, u32 offset): strings, objects, main, libraryIndex, libraries, classes,
members, codes, sourcePositions, sourceFiles, lineStarts, localVariables, coverage, annotations.
This is a TEST GENERATOR, not a verifier.
"""
import json
import pathlib
import random
import struct
import sys

SECTIONS = ["strings", "objects", "main", "library_index", "libraries", "classes", "members", "codes",
            "source_positions", "source_files", "line_starts", "local_variables", "coverage", "annotations"]


def header(b):
    magic, version = struct.unpack_from("<II", b, 0)
    secs = [struct.unpack_from("<II", b, 8 + i * 8) for i in range(14)]
    return magic, version, secs


def section_range(b, name):
    _, _, secs = header(b)
    i = SECTIONS.index(name)
    start = secs[i][1]
    later = sorted(off for _, off in secs if off > start)
    end = later[0] if later else len(b)
    return start, end


def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    n_random = int(sys.argv[sys.argv.index("--random") + 1]) if "--random" in sys.argv else 20
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 20261112
    base = src.read_bytes()
    magic, version, secs = header(base)
    assert magic == 0x44424333, "not a DBC3 module"
    out.mkdir(parents=True, exist_ok=True)
    cases = []

    def add(name, category, data, note):
        idx = len(cases) + 1
        fn = f"{idx:02d}_{name}.bc"
        (out / fn).write_bytes(bytes(data))
        cases.append({"file": fn, "name": name, "category": category, "size": len(data), "note": note})

    def setu32(b, off, v):
        b = bytearray(b)
        struct.pack_into("<I", b, off, v & 0xFFFFFFFF)
        return b

    def sec_off_field(name):
        return 8 + SECTIONS.index(name) * 8 + 4

    def sec_cnt_field(name):
        return 8 + SECTIONS.index(name) * 8

    # Truncation
    add("truncated_half", "truncated", base[: len(base) // 2], "first half only")
    add("truncated_header", "truncated", base[:60], "inside the section table")
    add("truncated_magic_only", "truncated", base[:8], "magic + version only")
    add("truncated_last_byte", "truncated", base[:-1], "last byte missing")
    cs, _ = section_range(base, "codes")
    add("truncated_at_codes", "truncated", base[:cs], "ends where the codes section starts")
    # Header
    add("bad_magic", "header", setu32(base, 0, 0x44424332), "magic DBC2")
    add("bad_version_next", "header", setu32(base, 4, version + 1), f"version {version + 1}")
    add("bad_version_zero", "header", setu32(base, 4, 0), "version 0")
    # Section table / sizes
    add("strings_offset_past_end", "section_table", setu32(base, sec_off_field("strings"), len(base) + 1000), "string table offset beyond EOF")
    add("objects_offset_zero", "section_table", setu32(base, sec_off_field("objects"), 0), "object table points at the header")
    add("codes_offset_huge", "section_table", setu32(base, sec_off_field("codes"), 0x7FFFFFF0), "codes offset 2 GB")
    add("libraries_count_huge", "section_table", setu32(base, sec_cnt_field("library_index"), 0xFFFF), "65535 libraries declared")
    add("libraries_count_zero", "section_table", setu32(base, sec_cnt_field("library_index"), 0), "no libraries")
    add("main_offset_zero", "missing_metadata", setu32(base, sec_off_field("main"), 0), "no entry point")
    allzero = bytearray(base)
    for i in range(14):
        struct.pack_into("<II", allzero, 8 + i * 8, 0, 0)
    add("all_sections_empty", "missing_metadata", allzero, "every section count/offset zero")
    # String table: references and interface metadata
    s0, s1 = section_range(base, "strings")
    text = base[s0:s1]
    def replace_in_strings(old, new, name, category, note):
        i = text.find(old)
        if i < 0:
            return
        b = bytearray(base)
        b[s0 + i: s0 + i + len(old)] = new
        add(name, category, b, note)
    replace_in_strings(b"package:app_core/app_core.dart", b"package:app_core/app_corX.dart", "unknown_host_library", "references", "host library URI changed")
    replace_in_strings(b"CatalogFeature", b"CatalogFeaturX", "unknown_host_class", "interface_metadata", "host interface class renamed")
    replace_in_strings(b"priceLabel", b"priceLabeX", "unknown_host_member", "interface_metadata", "overridden host member renamed")
    replace_in_strings(b"package:feature_catalog_patch1/", b"package:app_models/xxxxxxxxxxxxx", "module_library_collides", "references", "module library URI rewritten to a host package")
    b = bytearray(base)
    for k in range(s0, min(s1, s0 + 64)):
        b[k] ^= 0x5A
    add("strings_garbled", "corrupted_section", b, "first 64 bytes of the string table XOR 0x5A")
    # Object table (constant pool / references)
    o0, o1 = section_range(base, "objects")
    for j, frac in enumerate((0.1, 0.5, 0.9)):
        b = bytearray(base)
        k = o0 + int((o1 - o0) * frac)
        b[k] ^= 0xFF
        add(f"objects_flip_{j}", "constant_pool", b, f"object table byte at {k} inverted")
    # Codes (instruction sequences)
    c0, c1 = section_range(base, "codes")
    for j, frac in enumerate((0.05, 0.3, 0.6, 0.95)):
        b = bytearray(base)
        k = c0 + int((c1 - c0) * frac)
        b[k] = (b[k] + 0x37) & 0xFF
        add(f"codes_opcode_{j}", "instructions", b, f"code byte at {k} changed")
    b = bytearray(base)
    for k in range(c0, c1):
        b[k] = 0xFF
    add("codes_all_ff", "instructions", b, "whole codes section 0xFF")
    # Classes / members / libraries sections
    for name in ("libraries", "classes", "members"):
        a, z = section_range(base, name)
        if z > a:
            b = bytearray(base)
            for k in range(a, min(z, a + 16)):
                b[k] ^= 0xA5
            add(f"{name}_garbled", "corrupted_section", b, f"first 16 bytes of {name} XOR 0xA5")
    # Unexpected size/structure
    add("appended_garbage", "size", base + bytes(range(256)) * 4, "1 KB appended")
    add("duplicated_module", "size", base + base, "module repeated twice")
    # Seeded random mutations
    rng = random.Random(seed)
    for j in range(n_random):
        b = bytearray(base)
        kind = rng.choice(["flip", "flip", "flip", "insert", "delete", "overwrite"])
        if kind == "flip":
            for _ in range(rng.randint(1, 8)):
                k = rng.randrange(8, len(b))
                b[k] ^= 1 << rng.randrange(8)
        elif kind == "insert":
            k = rng.randrange(8, len(b))
            b[k:k] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 16)))
        elif kind == "delete":
            k = rng.randrange(8, len(b) - 16)
            del b[k: k + rng.randint(1, 16)]
        else:
            k = rng.randrange(8, len(b) - 32)
            b[k: k + 32] = bytes(rng.randrange(256) for _ in range(32))
        add(f"random_{j:02d}_{kind}", "random", b, f"seed {seed}, case {j}")
    (out / "corpus.json").write_text(json.dumps({"base_size": len(base), "seed": seed, "cases": cases}, indent=2))
    print(f"{len(cases)} cases in {out}")


if __name__ == "__main__":
    main()
