# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Copies verifier regression fixtures into the repository with local paths redacted.

    python3 -I make_fixtures.py <lab-dir> <fixtures-dir>

Modules embed absolute source paths of the build machine (Phase 2 finding). The user-name path
component is replaced by a placeholder OF THE SAME LENGTH, so every byte offset (including the
mutated instruction bytes) is unchanged. SHA-256 of each original and redacted file is recorded.
"""
import hashlib
import json
import pathlib
import sys

lab, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
home = pathlib.Path.home().name.encode()
placeholder = (b"redacted" + b"-" * len(home))[: len(home)] if len(home) <= 8 else (b"redacted-" + b"x" * len(home))[: len(home)]
corpus = lab / "work/p3art/corpus/bc"
valid = {name: lab / f"work/modules/{name}/module.bc" for name in ("patch_v1", "patch_v2", "patch_v4", "probe_lang", "probe_ui", "probe_state")}
malformed = {p.stem: p for p in sorted(corpus.glob("*.bc")) if "codes_" in p.stem or p.stem.startswith(("01_", "06_", "09_", "17_"))}
record = {"note": "user-name path component redacted with an equal-length placeholder", "files": {}}
for kind, items in (("valid", valid), ("malformed", malformed)):
    for name, src in items.items():
        data = src.read_bytes()
        red = data.replace(b"/home/" + home + b"/", b"/home/" + placeholder + b"/")
        assert len(red) == len(data)
        dst = out / kind / f"{name}.bc"
        dst.write_bytes(red)
        record["files"][f"{kind}/{name}.bc"] = {
            "original_sha256": hashlib.sha256(data).hexdigest(),
            "fixture_sha256": hashlib.sha256(red).hexdigest(),
            "size": len(data),
        }
base = lab / "work/modules/patch_v1/module.bc"
record["base_module_original_sha256"] = hashlib.sha256(base.read_bytes()).hexdigest()
(out / "fixtures.json").write_text(json.dumps(record, indent=2) + "\n")
print(len(record["files"]), "fixtures")
