# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
# Diffing uses the bsdiff4 package (BSD licence); the bsdiff 4 algorithm is by Colin Percival
# (BSD-2-Clause). See THIRD_PARTY_NOTICES.md.
"""OTADIF01: bsdiff 4 blocks, zlib-compressed, so the phone decodes them with dart:io alone.

Layout (little-endian int64): "OTADIF01" | new size | control len | diff len | extra len |
control | diff | extra. The reader is packages/ota_client/lib/src/bsdiff.dart.

Only the public bsdiff4.diff() and bsdiff4.patch() are used. Their BSDIFF40 output/input is the
standard bsdiff 4 format, converted here (KI-7: bsdiff4's internal helpers changed in 1.4.2).
BSDIFF40: "BSDIFF40" | control len | diff len | new size (8-byte sign-magnitude ints) |
bz2(control) | bz2(diff) | bz2(extra); control = triples of sign-magnitude ints.
"""

import bz2
import struct
import zlib

import bsdiff4

MAGIC = b"OTADIF01"
_BSDIFF40 = b"BSDIFF40"


def _offtin(b: bytes) -> int:
    """bsdiff's 8-byte sign-magnitude integer (bit 63 = sign)."""
    value = int.from_bytes(b, "little") & ~(1 << 63)
    return -value if b[7] & 0x80 else value


def _offtout(x: int) -> bytes:
    return (abs(x) | ((1 << 63) if x < 0 else 0)).to_bytes(8, "little")


def _read_bsdiff40(data: bytes) -> tuple[int, list[tuple[int, int, int]], bytes, bytes]:
    if data[:8] != _BSDIFF40:
        raise ValueError("not a BSDIFF40 patch")
    c_len, d_len, new_size = (_offtin(data[i : i + 8]) for i in (8, 16, 24))
    pos = 32
    control = bz2.decompress(data[pos : pos + c_len])
    diff_block = bz2.decompress(data[pos + c_len : pos + c_len + d_len])
    extra = bz2.decompress(data[pos + c_len + d_len :])
    controls = [
        tuple(_offtin(control[i + k : i + k + 8]) for k in (0, 8, 16)) for i in range(0, len(control), 24)
    ]
    return new_size, controls, diff_block, extra


def _write_bsdiff40(new_size: int, controls, diff_block: bytes, extra: bytes) -> bytes:
    control = bz2.compress(b"".join(_offtout(v) for triple in controls for v in triple))
    diff_c, extra_c = bz2.compress(diff_block), bz2.compress(extra)
    header = _BSDIFF40 + _offtout(len(control)) + _offtout(len(diff_c)) + _offtout(new_size)
    return header + control + diff_c + extra_c


def diff(old: bytes, new: bytes) -> bytes:
    # bsdiff packs control ints as sign-magnitude; OTADIF01 uses plain two's complement.
    new_size, controls, diff_block, extra_block = _read_bsdiff40(bsdiff4.diff(old, new))
    if new_size != len(new):
        raise ValueError("bsdiff4 reported an unexpected size")
    control = b"".join(struct.pack("<qqq", x, y, z) for x, y, z in controls)
    blocks = [zlib.compress(b, 9) for b in (control, diff_block, extra_block)]
    return MAGIC + struct.pack("<qqqq", len(new), *map(len, blocks)) + b"".join(blocks)


def patch(old: bytes, data: bytes) -> bytes:
    """Reference implementation of the phone side, used to check a patch before upload."""
    if data[:8] != MAGIC:
        raise ValueError("not an OTADIF01 patch")
    new_size, c_len, d_len, e_len = struct.unpack("<qqqq", data[8:40])
    pos = 40
    control = zlib.decompress(data[pos : pos + c_len])
    diff_block = zlib.decompress(data[pos + c_len : pos + c_len + d_len])
    extra = zlib.decompress(data[pos + c_len + d_len : pos + c_len + d_len + e_len])
    controls = [struct.unpack("<qqq", control[i : i + 24]) for i in range(0, len(control), 24)]
    out = bsdiff4.patch(old, _write_bsdiff40(new_size, controls, diff_block, extra))
    if len(out) != new_size:
        raise ValueError("size mismatch")
    return out
