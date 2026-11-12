# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Flutter OTA System local demo: seed, publish a test patch, and verify the end-to-end flow.

Runs inside the "tools" Compose service (the API image: Python stdlib + cryptography):

    docker compose --profile tools run --rm tools seed
    docker compose --profile tools run --rm tools publish [--banner TEXT] [--color '#RRGGBB']
    docker compose --profile tools run --rm tools verify

What this proves: the control plane and artifact data plane work (registration, update check,
download from object storage, SHA-256 and ES256 signature checks, rollback, revoke).

What it does NOT prove: executing new Dart code. The demo patch uses the "mock-v1" format, an
inert signed JSON file that the example app (packages/ota_client/example) reads at start. Android AOT code patches are a separate,
experimental path (docs/releases-and-patches.md) that needs a real device build.

The signature check below re-implements the canonical message from ADR-0002 independently of
backend/app/canonical.py, so a protocol drift between server and this script fails loudly.
Exit code: 0 = every check passed, 1 = at least one failed, 2 = usage/setup error.
"""

import argparse
import base64
import hashlib
import json
import os
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

API = os.environ.get("FLUTTER_OTA_API_URL", "http://api:8000").rstrip("/")
ADMIN_KEY = os.environ.get("OTA_ADMIN_API_KEY", "")
CDN_PUBLIC = os.environ.get("FLUTTER_OTA_CDN_PUBLIC_URL", "").rstrip("/")
CDN_INTERNAL = os.environ.get("FLUTTER_OTA_CDN_INTERNAL_URL", "").rstrip("/")
APP = os.environ.get("FLUTTER_OTA_DEMO_APP", "flutter-ota-system-demo")
CHANNEL = os.environ.get("FLUTTER_OTA_DEMO_CHANNEL", "dev")
RELEASE = os.environ.get("FLUTTER_OTA_DEMO_RELEASE", "1.0.0+1")
PLATFORM = os.environ.get("FLUTTER_OTA_DEMO_PLATFORM", "android")
ARCH = os.environ.get("FLUTTER_OTA_DEMO_ARCH", "arm64-v8a")
FORMAT = "mock-v1"

ADMIN = {"X-API-Key": ADMIN_KEY}


# ---- tiny HTTP helpers (stdlib only, so the production API image needs no extra package) --


class Response:
    def __init__(self, method: str, url: str, status_code: int, content: bytes):
        self.method, self.url, self.status_code, self.content = method, url, status_code, content

    @property
    def text(self) -> str:
        return self.content.decode("utf-8", "replace")

    def json(self):
        return json.loads(self.content)


def request(method: str, url: str, *, headers=None, params=None, json_body=None, data=None, files=None) -> Response:
    headers = dict(headers or {})
    body = None
    if params:
        url += "?" + urllib.parse.urlencode(params)
    if json_body is not None:
        body = json.dumps(json_body).encode()
        headers["Content-Type"] = "application/json"
    elif files:
        boundary = uuid.uuid4().hex
        parts = [
            f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
            for k, v in (data or {}).items()
        ]
        for name, (filename, content, *ctype) in files.items():
            head = (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
                    f"Content-Type: {ctype[0] if ctype else 'application/octet-stream'}\r\n\r\n")
            parts.append(head.encode() + content + b"\r\n")
        body = b"".join(parts) + f"--{boundary}--\r\n".encode()
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    elif data is not None:
        body = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return Response(method, url, r.status, r.read())
    except urllib.error.HTTPError as e:
        return Response(method, url, e.code, e.read())


class Client:
    def __init__(self, base_url: str):
        self.base_url = base_url

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def get(self, path: str, **kw) -> Response:
        return request("GET", self.base_url + path, **kw)

    def post(self, path: str, json=None, **kw) -> Response:
        return request("POST", self.base_url + path, json_body=json, **kw)


def http() -> Client:
    return Client(API)


def expect(resp: Response, *codes: int) -> Response:
    if resp.status_code not in codes:
        raise SystemExit(f"FATAL {resp.method} {resp.url} -> {resp.status_code}: {resp.text[:300]}")
    return resp


def find_release(c: Client) -> dict | None:
    releases = expect(c.get(f"/v1/admin/apps/{APP}/releases", headers=ADMIN), 200).json()
    return next((r for r in releases if r["platform"] == PLATFORM and r["version"] == RELEASE), None)


def internal_url(public_url: str) -> str:
    """The device URL, fetched through the Compose network (same bytes, same nginx)."""
    if CDN_PUBLIC and CDN_INTERNAL and public_url.startswith(CDN_PUBLIC + "/"):
        return CDN_INTERNAL + public_url[len(CDN_PUBLIC):]
    return public_url


# ---- canonical message (ADR-0002), independent re-implementation -------------------------


def canonical_message(fields: list[str]) -> bytes:
    out = bytearray(b"OTA-PATCH-V1\n")
    for f in fields:
        data = f.encode("utf-8")
        out += struct.pack(">I", len(data)) + data
    return bytes(out)


def signed_fields(app_id: str, release_id: str, patch: dict) -> list[str]:
    return [
        "1",  # protocol version
        app_id,
        release_id,
        str(patch["number"]),
        PLATFORM,
        patch["arch"],
        patch["runtime_abi"],
        patch["artifact_format"],
        patch["base_artifact_sha256"].lower(),
        patch["payload_sha256"].lower(),
        patch["result_sha256"].lower(),
        str(patch["size_bytes"]),
    ]


def load_public_key(info: dict) -> ec.EllipticCurvePublicKey:
    point = base64.b64decode(info["uncompressed_point_base64"])
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), point)


def es256_ok(pub: ec.EllipticCurvePublicKey, message: bytes, sig_b64: str) -> bool:
    try:
        raw = base64.b64decode(sig_b64, validate=True)
    except ValueError:
        return False
    if len(raw) != 64:
        return False
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    try:
        pub.verify(der, message, ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


# ---- commands -----------------------------------------------------------------------------


def cmd_seed(_args) -> int:
    with http() as c:
        expect(c.get("/health/ready"), 200)
        r = c.post("/v1/admin/apps", headers=ADMIN,
                   json={"slug": APP, "name": "Flutter OTA System Demo", "distribution": "enterprise"})
        expect(r, 201, 409)
        print(f"application  {APP}  ({'created' if r.status_code == 201 else 'already exists'})")

        channels = expect(c.get(f"/v1/admin/apps/{APP}/channels", headers=ADMIN), 200).json()
        if CHANNEL not in channels:
            expect(c.post(f"/v1/admin/apps/{APP}/channels", headers=ADMIN, data={"name": CHANNEL}), 201)
        print(f"channel      {CHANNEL}")

        if find_release(c) is None:
            expect(c.post(f"/v1/admin/apps/{APP}/releases", headers=ADMIN,
                          json={"platform": PLATFORM, "version": RELEASE}), 201)
            print(f"release      {PLATFORM} {RELEASE}  (created)")
        else:
            print(f"release      {PLATFORM} {RELEASE}  (already exists)")

        key = expect(c.get("/v1/admin/signing-key", headers=ADMIN), 200).json()
        print(f"signing key  {key['key_id']} (LOCAL DEVELOPMENT KEY - not for production)")
        apps = expect(c.get("/v1/admin/apps", headers=ADMIN), 200).json()
        app_id = next(a["id"] for a in apps if a["slug"] == APP)
        print("\nFor the example app (packages/ota_client/example), pass:")
        print(f"  --dart-define=OTA_APP={APP} --dart-define=OTA_CHANNEL={CHANNEL} \\")
        print(f"  --dart-define=OTA_APPLICATION_ID={app_id} \\")
        print(f"  --dart-define=OTA_PUBLIC_KEY={key['key_id']}:{key['uncompressed_point_base64']}")
    return 0


def cmd_publish(args) -> int:
    payload = json.dumps({"banner": args.banner, "color": args.color}, sort_keys=True).encode()
    with http() as c:
        release = find_release(c)
        if release is None:
            raise SystemExit("FATAL release not found: run ./scripts/seed_demo.sh first")
        patch = expect(c.post(f"/v1/admin/releases/{release['id']}/patches", headers=ADMIN,
                              json={"artifact_format": FORMAT, "note": "Flutter OTA System demo test patch"}), 201).json()
        expect(c.post(f"/v1/admin/patches/{patch['id']}/artifacts", headers=ADMIN,
                      data={"arch": ARCH}, files={"file": ("payload.json", payload, "application/json")}), 201)
        patch = expect(c.post(f"/v1/admin/patches/{patch['id']}/publish", headers=ADMIN,
                              json={"channel": CHANNEL, "rollout_percent": 100}), 200).json()
    art = patch["artifacts"][0]
    print(f"published patch #{patch['number']}  id={patch['id']}")
    print(f"  channel={CHANNEL} rollout=100%  format={FORMAT} (inert JSON, not executable code)")
    print(f"  sha256={art['payload_sha256']}  size={art['size_bytes']}  key_id={art['key_id']}")
    print(f"  url={art['url']}")
    return 0


class Checks:
    def __init__(self):
        self.failed = 0

    def __call__(self, name: str, ok: bool, detail: str = "") -> bool:
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))
        self.failed += 0 if ok else 1
        return ok


def cmd_verify(_args) -> int:
    check = Checks()
    with http() as c:
        check("backend liveness /health/live", c.get("/health/live").status_code == 200)
        check("database connectivity /health/ready", c.get("/health/ready").status_code == 200)
        check("admin API rejects a missing key", c.get("/v1/admin/apps").status_code == 401)

        release = find_release(c)
        if not check("demo release exists", release is not None, f"{APP} {PLATFORM} {RELEASE}"):
            print("Run ./scripts/seed_demo.sh and ./scripts/publish_test_patch.sh first.")
            return 1

        key_info = expect(c.get("/v1/admin/signing-key", headers=ADMIN), 200).json()
        pub = load_public_key(key_info)
        check("signing public key available", True, key_info["key_id"])

        # Device registration
        r = c.post("/v1/devices/register", json={
            "app": APP, "installation_id": f"verify-{uuid.uuid4()}", "platform": PLATFORM,
            "arch": ARCH, "release_version": RELEASE, "channel": CHANNEL})
        if not check("device registration", r.status_code == 200, f"HTTP {r.status_code}"):
            return 1
        device = {"Authorization": f"Bearer {r.json()['access_token']}"}
        check("update check rejects a missing device token",
              c.get("/v1/updates/check", params={"platform": PLATFORM, "arch": ARCH,
                                                 "release_version": RELEASE}).status_code == 401)

        def update_check(current: int = 0) -> dict:
            return expect(c.get("/v1/updates/check", headers=device, params={
                "platform": PLATFORM, "arch": ARCH, "release_version": RELEASE, "channel": CHANNEL,
                "current_patch_number": current, "supported_formats": FORMAT}), 200).json()

        res = update_check()
        if not check("update check offers a patch", res["update_available"] and res["patch"] is not None,
                     "run ./scripts/publish_test_patch.sh if this fails"):
            return 1
        patch = res["patch"]
        check("release matches", res["release_id"] == release["id"])

        # Download from object storage (nginx CDN), never through the API
        url = patch["download_url"]
        check("download URL is served by the CDN, not the API", "/cdn/patches/" in url and not url.startswith(API), url)
        dl = request("GET", internal_url(url))
        if not check("artifact download from local object storage", dl.status_code == 200, f"HTTP {dl.status_code}"):
            return 1
        body = dl.content
        check("download size matches", len(body) == patch["size_bytes"], f"{len(body)} bytes")

        digest = hashlib.sha256(body).hexdigest()
        check("SHA-256 verification", digest == patch["payload_sha256"], digest)
        check("mock-v1 result hash equals payload hash", patch["result_sha256"] == patch["payload_sha256"])

        fields = signed_fields(res["application_id"], res["release_id"], patch)
        msg = canonical_message(fields)
        check("signature key id is known", patch["key_id"] == key_info["key_id"], patch["key_id"])
        check("ES256 signature verification", es256_ok(pub, msg, patch["signature"]))

        # Negative tests: each must be rejected
        corrupted = bytearray(body)
        corrupted[0] ^= 0xFF
        check("corrupted artifact is rejected by SHA-256",
              hashlib.sha256(bytes(corrupted)).hexdigest() != patch["payload_sha256"])
        sig = bytearray(base64.b64decode(patch["signature"]))
        sig[10] ^= 0x01
        check("tampered signature is rejected", not es256_ok(pub, msg, base64.b64encode(bytes(sig)).decode()))
        other = list(fields)
        other[3] = str(patch["number"] + 1)
        check("signature does not cover a different patch number", not es256_ok(pub, canonical_message(other), patch["signature"]))
        other = list(fields)
        other[9] = hashlib.sha256(bytes(corrupted)).hexdigest()
        check("signature does not cover a substituted payload hash", not es256_ok(pub, canonical_message(other), patch["signature"]))
        other_key = ec.generate_private_key(ec.SECP256R1()).public_key()
        check("signature does not verify under a different key", not es256_ok(other_key, msg, patch["signature"]))
        check("public key PEM parses", isinstance(serialization.load_pem_public_key(key_info["pem"].encode()),
                                                  ec.EllipticCurvePublicKey))

        # Anti-rollback: a device already on this patch is not offered it again
        res2 = update_check(current=patch["number"])
        check("no re-offer to a device already on the patch", not res2["update_available"])

        # Rollback, then restore
        rb = c.post(f"/v1/admin/patches/{patch['id']}/rollback", headers=ADMIN)
        if check("rollback accepted", rb.status_code == 200, f"HTTP {rb.status_code}"):
            res3 = update_check(current=patch["number"])
            check("rolled-back patch listed and device told to roll back",
                  patch["number"] in res3["rolled_back_patch_numbers"] and res3["rollback_to_patch_number"] is not None,
                  f"rollback_to={res3['rollback_to_patch_number']}")
            rp = c.post(f"/v1/admin/patches/{patch['id']}/publish", headers=ADMIN,
                        json={"channel": CHANNEL, "rollout_percent": 100})
            check("re-publish after rollback", rp.status_code == 200, f"HTTP {rp.status_code}")

        # Revoke a throwaway patch (revoke is permanent, so never the main demo patch)
        tmp = expect(c.post(f"/v1/admin/releases/{release['id']}/patches", headers=ADMIN,
                            json={"artifact_format": FORMAT, "note": "verify_demo revoke test"}), 201).json()
        expect(c.post(f"/v1/admin/patches/{tmp['id']}/artifacts", headers=ADMIN, data={"arch": ARCH},
                      files={"file": ("p.json", json.dumps({"banner": f"revoke-test {uuid.uuid4()}"}).encode())}), 201)
        expect(c.post(f"/v1/admin/patches/{tmp['id']}/publish", headers=ADMIN,
                      json={"channel": CHANNEL, "rollout_percent": 100}), 200)
        offered = update_check()["patch"]
        check("newer patch is offered before revoke", offered is not None and offered["id"] == tmp["id"])
        expect(c.post(f"/v1/admin/patches/{tmp['id']}/revoke", headers=ADMIN), 200)
        res4 = update_check(current=tmp["number"])
        check("revoked patch is never offered", (res4["patch"] or {}).get("id") != tmp["id"])
        check("revoked patch listed for devices", tmp["number"] in res4["revoked_patch_numbers"])

    print()
    if check.failed:
        print(f"RESULT: {check.failed} check(s) FAILED")
        return 1
    print("RESULT: all checks passed (artifact pipeline; mock-v1 does not execute code)")
    return 0


def main() -> int:
    if not ADMIN_KEY:
        print("OTA_ADMIN_API_KEY is not set", file=sys.stderr)
        return 2
    p = argparse.ArgumentParser(prog="flutter_ota_system_demo")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("seed").set_defaults(fn=cmd_seed)
    pub = sub.add_parser("publish")
    pub.add_argument("--banner", default="Hello from a Flutter OTA System test patch")
    pub.add_argument("--color", default="#2E7D32")
    pub.set_defaults(fn=cmd_publish)
    sub.add_parser("verify").set_defaults(fn=cmd_verify)
    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
