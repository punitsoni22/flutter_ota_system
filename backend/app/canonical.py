# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Canonical patch message from ADR-0002. Must match the Dart encoder byte for byte."""

import struct
from dataclasses import dataclass

PREFIX = b"OTA-PATCH-V1\n"


def length_prefixed(*fields: str) -> bytes:
    out = bytearray()
    for field in fields:
        data = field.encode("utf-8")
        out += struct.pack(">I", len(data))
        out += data
    return bytes(out)


@dataclass(frozen=True)
class SignedFields:
    application_id: str
    release_id: str
    patch_number: int
    platform: str
    arch: str
    runtime_abi: str
    artifact_format: str
    base_artifact_sha256: str
    payload_sha256: str
    result_sha256: str
    size_bytes: int
    protocol_version: str = "1"

    def message(self) -> bytes:
        return PREFIX + length_prefixed(
            self.protocol_version,
            self.application_id,
            self.release_id,
            str(self.patch_number),
            self.platform,
            self.arch,
            self.runtime_abi,
            self.artifact_format,
            self.base_artifact_sha256.lower(),
            self.payload_sha256.lower(),
            self.result_sha256.lower(),
            str(self.size_bytes),
        )
