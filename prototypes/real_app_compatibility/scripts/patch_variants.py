# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Derives damaged patch files for the Part 12 crash/recovery tests from one valid .otp file.

    python3 -I scripts/patch_variants.py <valid.otp> <out-dir>

Each output differs from the valid patch in exactly one way.
"""
import hashlib
import json
import pathlib
import struct
import sys

MAGIC = b"OTAPRT01"


def parse(data: bytes):
    (n,) = struct.unpack(">I", data[8:12])
    return json.loads(data[12:12 + n]), data[12 + n:]


def build(manifest: dict, module: bytes) -> bytes:
    m = json.dumps(manifest, sort_keys=True).encode()
    return MAGIC + struct.pack(">I", len(m)) + m + module


def main() -> None:
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    data = src.read_bytes()
    manifest, module = parse(data)

    def write(name: str, blob: bytes) -> None:
        (out / name).write_bytes(blob)
        print(f"{name:30} {len(blob):7} bytes")

    # Partially written file (download/copy interrupted): first 60 % of the bytes.
    write("partial_write.otp", data[: len(data) * 6 // 10])
    # Corrupted metadata: the manifest bytes are not JSON (length field still consistent).
    bad = b"{not json" + b" " * 40
    write("corrupt_manifest.otp", MAGIC + struct.pack(">I", len(bad)) + bad + module)
    # Module that passes every manifest check (size + SHA-256 recomputed) but is not loadable
    # bytecode: the VM loader itself must fail safely.
    cut = module[: len(module) // 2]
    write("unloadable_module.otp", build({**manifest, "module_size": len(cut), "module_sha256": hashlib.sha256(cut).hexdigest()}, cut))
    # Built for another Flutter/runtime version (Part 13.9).
    write("other_runtime.otp", build({**manifest, "runtime": "proto-dbc-flutter-3.48.0"}, module))
    # Built for another baseline (Part 13.10 / patch for an older store release).
    write("other_baseline.otp", build({**manifest, "baseline_id": "22222222-2222-4222-8222-222222222222"}, module))


if __name__ == "__main__":
    main()
