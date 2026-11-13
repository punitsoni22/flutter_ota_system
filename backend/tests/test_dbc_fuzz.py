# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Deterministic mutation fuzzing of the dbc-v1 upload and the revocation-list upload.

Starts from a valid, correctly signed container (helpers from test_dbc.py) and uploads seeded
mutations through the real HTTP endpoint. Every mutated file must be refused with a clean 4xx
whose body is {"detail": "<code>: <reason>"}; a 5xx, an unhandled exception or an accepted file
(other than the unchanged original) is a failure. Structured edits are always invalid by design
(wrong types, missing or unknown fields, non-canonical JSON, oversized or deeply nested values),
including edits that are re-signed with the real signer or root key.

Seed and size: OTA_FUZZ_SEED (default 20261113) and OTA_FUZZ_CASES (default 2000).
"""

import copy
import io
import json
import os
import random
import struct
import time

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import ADMIN
from tests.test_dbc import (
    KEY_CERT_DOMAIN,
    MANIFEST_DOMAIN,
    Dev,
    canonical,
    container,
    raw_sig,
    revocation_list,
)

SEED = int(os.environ.get("OTA_FUZZ_SEED", "20261113"))
CASES = int(os.environ.get("OTA_FUZZ_CASES", "2000"))
TIME_BUDGET_S = 30.0
INTERESTING_U32 = (0, 1, 2, 15, 16, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x10001,
                   0x2000, 0x2001, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF)
INTERESTING_BYTES = b"\x00\x01\x7f\x80\xff\"{}[]\\,:0-eE.\n "
# Values that are invalid for every manifest/certificate field: the field types are str, int,
# list or dict, and each replacement below is chosen to differ from the original type.
WRONG_FOR = {
    str: (None, True, 0, -1, 2**64, [], {}, ["x"]),
    int: (None, True, False, "1", "", [], {}, [1]),
    bool: (None, 0, "true", []),
    list: (None, 0, "", {}, "[]", True),
    dict: (None, 0, "", [], "{}", True),
}


def parts(data: bytes) -> tuple[bytes, bytes, bytes]:
    m_len = struct.unpack(">I", data[8:12])[0]
    s_len = struct.unpack(">I", data[12 + m_len:16 + m_len])[0]
    return data[12:12 + m_len], data[16 + m_len:16 + m_len + s_len], data[16 + m_len + s_len:]


def paths(value, prefix=()):
    """Every (path) to a dict value or list element inside a JSON value."""
    if isinstance(value, dict):
        for k, v in value.items():
            yield prefix + (k,)
            yield from paths(v, prefix + (k,))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield prefix + (i,)
            yield from paths(v, prefix + (i,))


def get_at(value, path):
    for p in path:
        value = value[p]
    return value


def set_at(value, path, new):
    get_at(value, path[:-1])[path[-1]] = new


def dicts(value, prefix=()):
    if isinstance(value, dict):
        yield prefix
        for k, v in value.items():
            yield from dicts(v, prefix + (k,))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from dicts(v, prefix + (i,))


def json_edit(rng: random.Random, obj: dict, deletable) -> tuple[str, dict]:
    """One always-invalid structured edit of a parsed JSON object (returns a modified copy)."""
    obj = copy.deepcopy(obj)
    kind = rng.choice(("wrong_type", "delete", "unknown_key", "oversized", "deep"))
    all_paths = list(paths(obj))
    if kind == "wrong_type":
        path = rng.choice(all_paths)
        old = get_at(obj, path)
        set_at(obj, path, copy.deepcopy(rng.choice(WRONG_FOR[type(old)])))
        return f"wrong_type {'.'.join(map(str, path))}", obj
    if kind == "delete":
        candidates = [p for p in all_paths if isinstance(p[-1], str) and deletable(p)]
        path = rng.choice(candidates)
        del get_at(obj, path[:-1])[path[-1]]
        return f"delete {'.'.join(map(str, path))}", obj
    if kind == "unknown_key":
        path = rng.choice(list(dicts(obj)))
        get_at(obj, path)["zz_unknown"] = rng.choice((0, "x", None, [], {}))
        return f"unknown_key {'.'.join(map(str, path))}", obj
    if kind == "oversized":
        path = rng.choice([p for p in all_paths if isinstance(get_at(obj, p), str)])
        set_at(obj, path, "A" * rng.choice((65, 257, 9000, 70000)))
        return f"oversized {'.'.join(map(str, path))}", obj
    # Deep nesting: a common parser/encoder failure mode (recursion limits). Depths near or above
    # Python's recursion limit are covered by test_deep_nesting_is_refused_cleanly (known bug).
    path = rng.choice(all_paths)
    depth = rng.choice((64, 500))
    nested = 0
    for _ in range(depth):
        nested = [nested]
    set_at(obj, path, nested)
    return f"deep{depth} {'.'.join(map(str, path))}", obj


def raw_json(value) -> bytes:
    """Canonical-looking bytes for values that canonical() cannot encode (deep nesting)."""
    import sys

    old = sys.getrecursionlimit()
    sys.setrecursionlimit(max(old, 20000))
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    finally:
        sys.setrecursionlimit(old)


def byte_mutation(rng: random.Random, data: bytes) -> tuple[str, bytes]:
    b = bytearray(data)
    kind = rng.choice(("bitflip", "byte", "truncate", "trailing", "insert", "delete", "length", "splice"))
    if kind == "bitflip":
        n = rng.choice((1, 1, 2, 4, 8))
        for _ in range(n):
            i = rng.randrange(len(b))
            b[i] ^= 1 << rng.randrange(8)
        return f"bitflip x{n}", bytes(b)
    if kind == "byte":
        i = rng.randrange(len(b))
        b[i] = rng.choice(INTERESTING_BYTES) if rng.random() < 0.5 else rng.randrange(256)
        return f"byte @{i}", bytes(b)
    if kind == "truncate":
        n = rng.randrange(len(b))
        return f"truncate {n}", bytes(b[:n])
    if kind == "trailing":
        extra = rng.randbytes(rng.choice((1, 2, 64, 4096)))
        return f"trailing +{len(extra)}", bytes(b) + extra
    if kind == "insert":
        i = rng.randrange(len(b) + 1)
        return f"insert @{i}", bytes(b[:i]) + rng.randbytes(rng.choice((1, 3, 16))) + bytes(b[i:])
    if kind == "delete":
        i = rng.randrange(len(b))
        n = rng.choice((1, 2, 16))
        return f"delete @{i}+{n}", bytes(b[:i] + b[i + n:])
    if kind == "length":
        m_len = struct.unpack(">I", data[8:12])[0]
        which = rng.choice(("manifest", "signature"))
        off = 8 if which == "manifest" else 12 + m_len
        cur = struct.unpack(">I", data[off:off + 4])[0]
        value = rng.choice(INTERESTING_U32 + tuple(max(0, cur + d) for d in (-2, -1, 1, 2, 7)))
        if value == cur:
            value = cur + 1
        b[off:off + 4] = struct.pack(">I", value & 0xFFFFFFFF)
        return f"length {which}={value}", bytes(b)
    # Splice: a random chunk copied over another position.
    i, j = rng.randrange(len(b)), rng.randrange(len(b))
    n = rng.randrange(1, 32)
    chunk = bytes(b[i:i + n])
    b[j:j + len(chunk)] = chunk
    return f"splice {i}->{j}+{n}", bytes(b)


class Case:
    def __init__(self, label: str, data: bytes):
        self.label, self.data = label, data


def dbc_cases(dev: Dev, good: bytes, module: bytes, rng: random.Random, n: int):
    manifest_bytes, sig_bytes, _ = parts(good)
    manifest = json.loads(manifest_bytes)
    block = json.loads(sig_bytes)
    # Deleting expires_at (optional) or approvals (absent) is valid; everything else is required.
    required = lambda p: p not in (("expires_at",), ("approvals",))  # noqa: E731
    for _ in range(n):
        r = rng.random()
        if r < 0.55:
            label, data = byte_mutation(rng, good)
        elif r < 0.70:  # manifest edit, original signature kept
            label, m = json_edit(rng, manifest, required)
            label, data = "manifest " + label, container(raw_json(m), sig_bytes, module)
        elif r < 0.80:  # manifest edit, re-signed by the real certified signer
            label, m = json_edit(rng, manifest, required)
            body = raw_json(m)
            sig = dict(block, sig=raw_sig(dev.signer, MANIFEST_DOMAIN, body))
            label, data = "manifest+resigned " + label, container(body, canonical(sig), module)
        elif r < 0.90:  # signature block edit (the block itself is not signed)
            label, s = json_edit(rng, block, required)
            label, data = "sigblock " + label, container(manifest_bytes, raw_json(s), module)
        elif r < 0.95:  # certificate body edit, re-signed by the real root key
            label, body = json_edit(rng, block["cert"]["body"], required)
            cert = dict(block["cert"], body=body)
            try:
                cert["sig"] = raw_sig(dev.root, KEY_CERT_DOMAIN, canonical(body))
            except (ValueError, RecursionError):
                pass  # not encodable canonically (deep nesting): keep the old signature
            label, data = "cert+resigned " + label, container(manifest_bytes, raw_json(dict(block, cert=cert)), module)
        else:  # non-canonical but equivalent JSON (whitespace / key order / escapes), re-signed
            style = rng.choice(("indent", "unsorted", "ascii"))
            if style == "indent":
                body = json.dumps(manifest, sort_keys=True, indent=1).encode()
            elif style == "unsorted":
                body = json.dumps(dict(reversed(list(manifest.items()))), separators=(",", ":")).encode()
            else:
                body = manifest_bytes.replace(b'"format"', b'"\\u0066ormat"', 1)
            sig = dict(block, sig=raw_sig(dev.signer, MANIFEST_DOMAIN, body))
            label, data = f"noncanonical {style} resigned", container(body, canonical(sig), module)
        yield Case(label, data)


def run_cases(cases, upload, original: bytes, budget_s: float):
    stats, failures, started = {}, [], time.monotonic()
    count = 0
    for case in cases:
        if case.data == original:
            continue
        count += 1
        try:
            r = upload(case.data)
        except Exception as exc:  # noqa: BLE001 - an unhandled server exception is a finding
            failures.append(f"{case.label}: unhandled {type(exc).__name__}: {str(exc)[:120]}")
            continue
        if not 400 <= r.status_code < 500:
            failures.append(f"{case.label}: HTTP {r.status_code} {r.text[:160]}")
            continue
        detail = r.json().get("detail")
        if not isinstance(detail, str) or ": " not in detail:
            failures.append(f"{case.label}: unexpected body {r.text[:160]}")
            continue
        code = f"{r.status_code} {detail.split(':', 1)[0]}"
        stats[code] = stats.get(code, 0) + 1
    elapsed = time.monotonic() - started
    return count, stats, failures, elapsed


def report(name, count, stats, failures, elapsed):
    print(f"\n{name}: seed={SEED} cases={count} elapsed={elapsed:.1f}s")
    for code, n in sorted(stats.items(), key=lambda x: -x[1]):
        print(f"  {n:5d}  {code}")
    for f in failures[:40]:
        print(f"  FAIL {f}")


def test_dbc_upload_mutation_fuzz(client):
    dev = Dev(client)
    rng = random.Random(SEED)
    module = rng.randbytes(1500)
    good = dev.patch_file(module=module)
    pid = dev.new_patch()
    count, stats, failures, elapsed = run_cases(
        dbc_cases(dev, good, module, rng, CASES), lambda d: dev.upload(pid, d), good, TIME_BUDGET_S)
    report("dbc-v1 upload fuzz", count, stats, failures, elapsed)
    assert not failures, f"{len(failures)} of {count} mutations were not cleanly refused"
    assert elapsed < TIME_BUDGET_S, f"fuzz took {elapsed:.1f}s"
    # The unchanged original is still accepted afterwards (no state was corrupted by the fuzz).
    assert dev.upload(pid, good).status_code == 201


def test_revocation_upload_mutation_fuzz(client):
    dev = Dev(client)
    rng = random.Random(SEED + 1)
    good = revocation_list(dev.root, dev.root_id, dev.release_id, 1, key_ids=["old-signer"], serials=[7])
    body_bytes, sig_bytes, _ = parts(good)
    body, block = json.loads(body_bytes), json.loads(sig_bytes)
    # Every revocation field is required except revoked_cert_serials.
    required = lambda p: p != ("revoked_cert_serials",)  # noqa: E731

    def cases():
        for _ in range(CASES // 4):
            r = rng.random()
            if r < 0.6:
                label, data = byte_mutation(rng, good)
            elif r < 0.8:
                label, b = json_edit(rng, body, required)
                label, data = "body " + label, container(raw_json(b), sig_bytes, b"")
            else:
                label, s = json_edit(rng, block, required)
                label, data = "sigblock " + label, container(body_bytes, raw_json(s), b"")
            yield Case(label, data)

    def up(data):
        return dev.trust_post("revocations", files={"file": ("r.otp", io.BytesIO(data))})

    count, stats, failures, elapsed = run_cases(cases(), up, good, TIME_BUDGET_S)
    report("revocation upload fuzz", count, stats, failures, elapsed)
    assert not failures, f"{len(failures)} of {count} mutations were not cleanly refused"
    assert elapsed < TIME_BUDGET_S
    assert up(good).status_code == 201



@pytest.mark.xfail(strict=True, reason=(
    "known bug: JSON nested about 1000 levels deep raises RecursionError in dbc.canonical() and "
    "the server answers 500 instead of 4xx (dbc-v1 upload, revocation upload, certificate upload)"))
def test_deep_nesting_is_refused_cleanly(client):
    dev = Dev(client)
    good = dev.patch_file()
    manifest_bytes, sig_bytes, module = parts(good)
    nested = 0
    for _ in range(1000):
        nested = [nested]
    raw = TestClient(app, raise_server_exceptions=False)
    block = dict(json.loads(sig_bytes), alg=nested)
    results = [
        raw.post(f"/v1/admin/patches/{dev.new_patch()}/artifacts", data={"arch": "arm64-v8a"}, headers=ADMIN,
                 files={"file": ("p.otp", io.BytesIO(container(manifest_bytes, raw_json(block), module)))}),
        raw.post(f"/v1/admin/apps/{dev.app_id}/trust/revocations", headers=ADMIN,
                 files={"file": ("r.otp", io.BytesIO(container(raw_json({"type": nested}), b"{}", b"")))}),
        raw.post(f"/v1/admin/apps/{dev.app_id}/trust/certificates",
                 headers={**ADMIN, "Content-Type": "application/json"},
                 content=raw_json(dict(dev.cert, body=dict(dev.cert["body"], environment=nested)))),
    ]
    assert [r.status_code for r in results] == [422, 422, 422], [r.text[:80] for r in results]
