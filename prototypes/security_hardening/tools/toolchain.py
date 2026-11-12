# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Computes the toolchain record (Phase 3C provenance) from the actual local toolchain content.

    python3 -I tools/toolchain.py <lab-dir>        -> prints the JSON record (with "id")

Fields are content hashes, not version claims:
  compiler_sha256    sorted (path, sha256) of the pinned dart2bytecode sources (pkg/dart2bytecode)
  generator_sha256   sorted (path, sha256) of our generator tools (rename tool, policy, module
                     builder, guard, signer)
  engine_patch_sha256  the Dart VM patch applied to the engine
  build_config_sha256  the engine's GN args (out/android_release_arm64/args.gn)
  bytecode_format    KernelBytecode::kBytecodeFormatVersion of the pinned VM
id = SHA-256 of the canonical JSON of all other fields (same encoding as package:patch_security).
"""
import hashlib
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent


def tree_hash(root: pathlib.Path, paths) -> str:
    entries = []
    for p in paths:
        for f in sorted(p.rglob("*") if p.is_dir() else [p]):
            if f.is_file() and not any(part.startswith(".") for part in f.relative_to(root).parts):
                entries.append(f"{f.relative_to(root).as_posix()}\0{hashlib.sha256(f.read_bytes()).hexdigest()}")
    return hashlib.sha256("\n".join(sorted(entries)).encode()).hexdigest()


def pins():
    out = {}
    for line in (HERE.parent / "bytecode_engine/pins.env").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def main():
    lab = pathlib.Path(sys.argv[1])
    p = pins()
    dart = lab / "engine/engine/src/flutter/third_party/dart"
    fmt = int(re.search(r"kBytecodeFormatVersion = (\d+);", (dart / "runtime/vm/constants_kbc.h").read_text()).group(1))
    repo = HERE.parent
    fields = {
        "flutter": p["FLUTTER_VERSION"],
        "dart": p["DART_VERSION"],
        "engine": p["ENGINE_COMMIT"][:8],
        "dart_revision": p["DART_REVISION"][:8],
        "engine_patch_sha256": hashlib.sha256((HERE / "engine_patch/0001-dart-bytecode-verifier.patch").read_bytes()).hexdigest(),
        "compiler_sha256": tree_hash(dart, [dart / "pkg/dart2bytecode/lib", dart / "pkg/dart2bytecode/bin"]),
        "generator_sha256": tree_hash(repo, [
            repo / "real_app_compatibility/tools/pkg_rename/bin/pkg_rename.dart",
            repo / "real_app_compatibility/tools/policy.yaml",
            repo / "real_app_compatibility/scripts/make_module.sh",
            HERE / "tools/patch_guard/bin/patch_guard.dart",
            HERE / "tools/sign_patch.py",
        ]),
        "bytecode_format": fmt,
        "build_config_sha256": hashlib.sha256((lab / "engine/engine/src/out/android_release_arm64/args.gn").read_bytes()).hexdigest(),
    }
    body = json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    print(json.dumps({**fields, "id": hashlib.sha256(body).hexdigest()}, indent=2))


if __name__ == "__main__":
    main()
