# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Phase 3 prototype signer for patch container v2 (NOT the production signing service).

    python3 -I tools/sign_patch.py keygen --dir <lab-keys-dir> --key-id <id>
    python3 -I tools/sign_patch.py sign --key <private.pem> --key-id <id> --baseline <dir>
        --module <module.bc> --rename-report <name.rename.json> --module-config <package_config.json>
        --sequence N --out <patch.otp> [--patch-id UUID] [--expires-at ISO] [--created-at ISO]
        [--override field=json ...]        (negative tests only: replace a manifest field)
    python3 -I tools/sign_patch.py revoke --key <pem> --key-id <id> --release <uuid> --sequence N
        [--patch-id UUID ...] [--revoke-key-id ID ...] --out <revocations.otp>

ES256 (ECDSA P-256 + SHA-256), raw r||s base64 -- the primitive of backend/app/signing.py.
Private keys are written only to the lab directory (mode 600), never into the repository.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import pathlib
import struct
import sys
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

MAGIC = b"OTAPRT02"
MANIFEST_DOMAIN = b"flutter-ota-system/patch-manifest/v2\n"
REVOCATION_DOMAIN = b"flutter-ota-system/revocations/v1\n"


def canonical(obj) -> bytes:
    def check(v):
        if isinstance(v, float):
            raise ValueError("floats are not allowed in canonical JSON")
        if isinstance(v, dict):
            for k, x in v.items():
                if not isinstance(k, str) or not k.isascii():
                    raise ValueError("keys must be ASCII strings")
                check(x)
        if isinstance(v, list):
            for x in v:
                check(x)
    check(obj)
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sign(key_path: str, key_id: str, domain: bytes, body: bytes) -> bytes:
    key = serialization.load_pem_private_key(pathlib.Path(key_path).read_bytes(), password=None)
    r, s = decode_dss_signature(key.sign(domain + body, ec.ECDSA(hashes.SHA256())))
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return canonical({"alg": "ES256", "key_id": key_id, "sig": base64.b64encode(raw).decode()})


def container(manifest: bytes, signature: bytes, module: bytes) -> bytes:
    return MAGIC + struct.pack(">I", len(manifest)) + manifest + struct.pack(">I", len(signature)) + signature + module


def keygen(a):
    d = pathlib.Path(a.dir)
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    pem = d / f"{a.key_id}.pem"
    if pem.exists():
        sys.exit(f"refusing to overwrite {pem}")
    key = ec.generate_private_key(ec.SECP256R1())
    fd = os.open(pem, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    point = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    (d / f"{a.key_id}.pub").write_text(base64.b64encode(point).decode())
    print(json.dumps({"key_id": a.key_id, "public": base64.b64encode(point).decode()}))


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def cmd_sign(a):
    base = pathlib.Path(a.baseline)
    b = json.loads((base / "baseline.json").read_text())
    module = pathlib.Path(a.module).read_bytes()
    report = json.loads(pathlib.Path(a.rename_report).read_text())
    renames = report.get("renames", {})
    lock = (base / "pubspec.lock").read_text()
    def version_of(name):
        import re
        m = re.search(rf"^  {re.escape(name)}:\n(?:    .*\n)*?    version: \"([^\"]+)\"", lock, re.M)
        return m.group(1) if m else "1.0.0"
    cfg = json.loads(pathlib.Path(a.module_config).read_text())
    module_pkgs = set(renames.values()) | {report["module"]}
    host_pkgs = sorted(p["name"] for p in cfg["packages"] if p["name"] not in module_pkgs and p["name"] not in renames)
    internal = set(json.loads((base / "host_packages.json").read_text())["internal"])
    manifest = {
        "format": 2,
        "app_id": b["app_id"],
        "release_id": b["baseline_id"],
        "baseline_libapp_sha256": b["libapp_sha256"],
        "patch_id": a.patch_id or str(uuid.uuid4()),
        "sequence": a.sequence,
        "key_id": a.key_id,
        "created_at": a.created_at or now_iso(),
        "runtime": b["runtime_info"],
        "module": {"format": "dart-bytecode", "sha256": hashlib.sha256(module).hexdigest(), "size": len(module), "entry_contract": 2},
        "packages": sorted(({"name": n, "module_name": r, "version": version_of(n), "source": "internal" if n in internal else "hosted"}
                            for n, r in renames.items()), key=lambda p: p["name"]),
        "host_interface": {"sha256": b["interface_sha256"], "host_packages": host_pkgs},
        "assets": [],
    }
    if a.expires_at:
        manifest["expires_at"] = a.expires_at
    for o in a.override or []:
        k, v = o.split("=", 1)
        cur = manifest
        *path, last = k.split(".")
        for p in path:
            cur = cur[p]
        if v == "__delete__":
            cur.pop(last, None)
        else:
            cur[last] = json.loads(v)
    body = canonical(manifest)
    out = container(body, sign(a.key, a.key_id, MANIFEST_DOMAIN, body), module)
    pathlib.Path(a.out).write_bytes(out)
    print(json.dumps({"patch_id": manifest["patch_id"], "sequence": a.sequence, "otp_size": len(out), "module_size": len(module)}))


def cmd_revoke(a):
    body = canonical({"type": "revocations", "release_id": a.release, "sequence": a.sequence,
                      "revoked_patch_ids": sorted(a.patch_id or []), "revoked_key_ids": sorted(a.revoke_key_id or [])})
    pathlib.Path(a.out).write_bytes(container(body, sign(a.key, a.key_id, REVOCATION_DOMAIN, body), b""))
    print("ok")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("keygen"); k.add_argument("--dir", required=True); k.add_argument("--key-id", required=True)
    s = sub.add_parser("sign")
    for f in ("key", "key-id", "baseline", "module", "rename-report", "module-config", "out"):
        s.add_argument(f"--{f}", required=True)
    s.add_argument("--sequence", type=int, required=True)
    s.add_argument("--patch-id"); s.add_argument("--expires-at"); s.add_argument("--created-at")
    s.add_argument("--override", action="append")
    r = sub.add_parser("revoke")
    for f in ("key", "key-id", "release", "out"):
        r.add_argument(f"--{f}", required=True)
    r.add_argument("--sequence", type=int, required=True)
    r.add_argument("--patch-id", action="append"); r.add_argument("--revoke-key-id", action="append")
    a = ap.parse_args()
    {"keygen": keygen, "sign": cmd_sign, "revoke": cmd_revoke}[a.cmd](a)


if __name__ == "__main__":
    main()
