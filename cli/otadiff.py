# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
# Diffing uses the bsdiff4 package (BSD licence); the bsdiff 4 algorithm is by Colin Percival
# (BSD-2-Clause). See THIRD_PARTY_NOTICES.md.
"""OTADIF01: bsdiff 4 blocks, zlib-compressed, so the phone decodes them with dart:io alone.

Layout (little-endian int64): "OTADIF01" | new size | control len | diff len | extra len |
control | diff | extra. The reader is packages/ota_client/lib/src/bsdiff.dart.
"""

import struct
from io import BytesIO
import zlib

import bsdiff4
import bsdiff4.core
import bsdiff4.format

MAGIC = b"OTADIF01"


def diff(old: bytes, new: bytes) -> bytes:
    # bsdiff packs control ints as sign-magnitude; OTADIF01 uses plain two's complement.
    bs_control, diff_block, extra_block = bsdiff4.core.diff(old, new)
    controls = bsdiff4.format.unpack_control_block(bs_control)
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
    bs = BytesIO()
    bsdiff4.format.write_patch(bs, new_size, bsdiff4.format.pack_control_block(*controls), diff_block, extra)
    out = bsdiff4.patch(old, bs.getvalue())
    if len(out) != new_size:
        raise ValueError("size mismatch")
    return out
