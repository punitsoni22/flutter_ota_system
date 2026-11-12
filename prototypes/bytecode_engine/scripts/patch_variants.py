# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Derives the invalid patch files for the negative tests from one valid .otp file.

    python3 -I scripts/patch_variants.py <valid.otp> <out-dir>

Writes one file per scenario; each differs from the valid patch in exactly one property.
"""
import hashlib
import json
import pathlib
import struct
import sys

MAGIC = b"OTAPRT01"


def parse(data: bytes):
    assert data[:8] == MAGIC
    (n,) = struct.unpack(">I", data[8:12])
    return json.loads(data[12:12 + n]), data[12 + n:]


def build(manifest: dict, module: bytes) -> bytes:
    m = json.dumps(manifest, sort_keys=True).encode()
    return MAGIC + struct.pack(">I", len(m)) + m + module


def main() -> None:
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    manifest, module = parse(src.read_bytes())

    def write(name: str, data: bytes) -> None:
        (out / name).write_bytes(data)
        print(f"{name:28} {len(data):7} bytes")

    flipped = bytearray(module)
    flipped[len(flipped) // 2] ^= 0xFF  # one bit-flipped byte in the bytecode
    write("corrupted_module.otp", build(manifest, bytes(flipped)))
    write("wrong_format.otp", build({**manifest, "format": 2}, module))
    write("wrong_runtime.otp", build({**manifest, "runtime": "proto-dbc-flutter-3.44.9"}, module))
    write("wrong_app.otp", build({**manifest, "app_id": "11111111-1111-4111-8111-111111111111"}, module))
    write("wrong_baseline.otp", build({**manifest, "baseline_id": "22222222-2222-4222-8222-222222222222"}, module))
    write("missing_module.otp", build(manifest, b""))
    write("garbage.otp", hashlib.sha256(b"not a patch").digest() * 64)


if __name__ == "__main__":
    main()
