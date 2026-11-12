# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""dbc-v1 (developer-signed bytecode patches), trust endpoints and UUID registration (Phase 4G).

Fixtures are built here with `cryptography`, exactly like the prototype signer
(prototypes/security_hardening/tools/sign_patch.py). Keys are generated per test, never stored.
"""

import base64
import hashlib
import io
import json
import os
import struct
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from tests.conftest import ADMIN
from tests.test_flow import make_app, make_patch, make_release

MAGIC = b"OTAPRT02"
MANIFEST_DOMAIN = b"flutter-ota-system/patch-manifest/v2\n"
REVOCATION_DOMAIN = b"flutter-ota-system/revocations/v1\n"
KEY_CERT_DOMAIN = b"flutter-ota-system/key-certificate/v1\n"
APPROVAL_DOMAIN = b"flutter-ota-system/patch-approval/v1\n"
ARCH = "arm64-v8a"


# ---- signer (same algorithm as sign_patch.py) --------------------------------------------


def canonical(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def raw_sig(key: ec.EllipticCurvePrivateKey, domain: bytes, body: bytes) -> str:
    r, s = decode_dss_signature(key.sign(domain + body, ec.ECDSA(hashes.SHA256())))
    return base64.b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode()


def pub_b64(key: ec.EllipticCurvePrivateKey) -> str:
    point = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return base64.b64encode(point).decode()


def container(manifest: bytes, signature: bytes, module: bytes) -> bytes:
    return MAGIC + struct.pack(">I", len(manifest)) + manifest + struct.pack(">I", len(signature)) + signature + module


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


NOW = datetime.now(timezone.utc).replace(microsecond=0)


def toolchain() -> dict:
    fields = {
        "flutter": "3.47.9", "dart": "3.11.0", "engine": "abc123", "dart_revision": "d1e2f3",
        "engine_patch_sha256": "1" * 64, "compiler_sha256": "2" * 64, "generator_sha256": "3" * 64,
        "bytecode_format": 1, "build_config_sha256": "4" * 64,
    }
    return {**fields, "id": hashlib.sha256(canonical(fields)).hexdigest()}


def issue_cert(root, root_key_id, app_id, key, key_id, serial, roles=("signer",), environment="production",
               not_before=None, not_after=None) -> dict:
    body = {
        "type": "key_cert", "app_id": app_id, "environment": environment, "key_id": key_id,
        "public_key": pub_b64(key), "roles": sorted(roles), "serial": serial,
        "not_before": iso(not_before or NOW - timedelta(days=1)),
        "not_after": iso(not_after or NOW + timedelta(days=365)),
    }
    return {"body": body, "root_key_id": root_key_id, "sig": raw_sig(root, KEY_CERT_DOMAIN, canonical(body))}


def revocation_list(root, root_key_id, release_id, sequence, patch_ids=(), key_ids=(), serials=None) -> bytes:
    body = {"type": "revocations", "release_id": release_id, "sequence": sequence,
            "revoked_patch_ids": sorted(patch_ids), "revoked_key_ids": sorted(key_ids)}
    if serials:
        body["revoked_cert_serials"] = sorted(serials)
    body = canonical(body)
    sig = canonical({"alg": "ES256", "key_id": root_key_id, "sig": raw_sig(root, REVOCATION_DOMAIN, body)})
    return container(body, sig, b"")


class Dev:
    """One developer setup: app, release with a base libapp.so, a root key and a certified signer."""

    def __init__(self, client, slug="demo"):
        self.client = client
        self.app = make_app(client, slug=slug)
        self.app_id = self.app["id"]
        self.slug = slug
        self.release_id = str(uuid.uuid4())
        r = client.post(
            f"/v1/admin/apps/{slug}/releases",
            json={"platform": "android", "version": "1.0.0+1", "id": self.release_id,
                  "toolchain_id": toolchain()["id"], "dart_revision": "d1e2f3", "bytecode_format": 1,
                  "interface_sha256": "5" * 64},
            headers=ADMIN,
        )
        assert r.status_code == 201, r.text
        assert r.json()["id"] == self.release_id and r.json()["toolchain_id"] == toolchain()["id"]
        self.libapp = os.urandom(4096)
        self.baseline_sha = hashlib.sha256(self.libapp).hexdigest()
        r = client.post(f"/v1/admin/releases/{self.release_id}/artifacts", data={"arch": ARCH},
                        files={"file": ("libapp.so", io.BytesIO(self.libapp))}, headers=ADMIN)
        assert r.status_code == 201, r.text
        self.root = ec.generate_private_key(ec.SECP256R1())
        self.root_id = "root-1"
        r = self.trust_post("roots", json={"key_id": self.root_id, "public_key": pub_b64(self.root)})
        assert r.status_code == 201, r.text
        self.signer = ec.generate_private_key(ec.SECP256R1())
        self.signer_id = "signer-1"
        self.cert = issue_cert(self.root, self.root_id, self.app_id, self.signer, self.signer_id, serial=1)

    def trust_post(self, path, **kwargs):
        return self.client.post(f"/v1/admin/apps/{self.app_id}/trust/{path}", headers=ADMIN, **kwargs)

    def manifest(self, module: bytes, sequence=1, patch_id=None, **override) -> dict:
        m = {
            "format": 2, "app_id": self.app_id, "release_id": self.release_id,
            "baseline_libapp_sha256": self.baseline_sha, "patch_id": patch_id or str(uuid.uuid4()),
            "sequence": sequence, "key_id": self.signer_id, "created_at": iso(NOW),
            "runtime": {"flutter": "3.47.9", "dart": "3.11.0", "engine": "abc123", "abi": "android-arm64",
                        "runtime_id": "ota-bc-1"},
            "module": {"format": "dart-bytecode", "sha256": hashlib.sha256(module).hexdigest(),
                       "size": len(module), "entry_contract": 2},
            "packages": [{"name": "feature_home", "module_name": "feature_home_p1", "version": "1.0.0",
                          "source": "internal"}],
            "host_interface": {"sha256": "5" * 64, "host_packages": ["flutter", "host_app"]},
            "assets": [],
            "toolchain": toolchain(),
        }
        m.update(override)
        return m

    def sign(self, manifest: dict, module: bytes, key=None, key_id=None, cert="default", approvals=None) -> bytes:
        body = canonical(manifest)
        block = {"alg": "ES256", "key_id": key_id or self.signer_id,
                 "sig": raw_sig(key or self.signer, MANIFEST_DOMAIN, body)}
        if cert is not None:
            block["cert"] = self.cert if cert == "default" else cert
        if approvals:
            block["approvals"] = approvals
        return container(body, canonical(block), module)

    def patch_file(self, sequence=1, patch_id=None, module=None, **override) -> bytes:
        module = module or os.urandom(2000)
        return self.sign(self.manifest(module, sequence, patch_id, **override), module)

    def new_patch(self) -> str:
        r = self.client.post(f"/v1/admin/releases/{self.release_id}/patches", json={"artifact_format": "dbc-v1"},
                             headers=ADMIN)
        assert r.status_code == 201, r.text
        return r.json()["id"]

    def upload(self, patch_id: str, data: bytes, arch=ARCH):
        return self.client.post(f"/v1/admin/patches/{patch_id}/artifacts", data={"arch": arch},
                                files={"file": ("patch.otp", io.BytesIO(data))}, headers=ADMIN)

    def publish(self, patch_id: str):
        r = self.client.post(f"/v1/admin/patches/{patch_id}/publish",
                             json={"channel": "production", "rollout_percent": 100}, headers=ADMIN)
        assert r.status_code == 200, r.text

    def device(self, installation_id="install-dbc-1") -> dict:
        r = self.client.post("/v1/devices/register", json={
            "application_id": self.app_id, "installation_id": installation_id, "platform": "android",
            "arch": ARCH, "release_version": "1.0.0+1"})
        assert r.status_code == 200, r.text
        return {"Authorization": f"Bearer {r.json()['access_token']}"}

    def check(self, headers, formats="dbc-v1", current=0) -> dict:
        r = self.client.get("/v1/updates/check", headers=headers, params={
            "platform": "android", "arch": ARCH, "release_version": "1.0.0+1", "current_patch_number": current,
            "supported_formats": formats})
        assert r.status_code == 200, r.text
        return r.json()


def expect(r, status_code: int, code: str):
    assert r.status_code == status_code, r.text
    assert r.json()["detail"].startswith(code + ":"), r.text


# ---- accept + device view ----------------------------------------------------------------


def test_dbc_upload_accepted_stored_unchanged_and_offered(client):
    from app.deps import get_storage

    dev = Dev(client)
    data = dev.patch_file(sequence=3, expires_at=iso(NOW + timedelta(days=30)))
    pid = dev.new_patch()
    r = dev.upload(pid, data)
    assert r.status_code == 201, r.text
    art = r.json()["artifacts"][0]
    assert art["signature"] is None and art["key_id"] is None  # the server never signs dbc-v1
    assert art["sequence"] == 3 and art["signer_key_id"] == "signer-1" and art["cert_serial"] == 1
    assert art["payload_sha256"] == hashlib.sha256(data).hexdigest() and art["size_bytes"] == len(data)
    assert art["base_artifact_sha256"] == dev.baseline_sha
    storage = get_storage()
    key = art["url"].split("/cdn/", 1)[1]
    assert b"".join(storage.read(key)) == data  # byte for byte

    dev.publish(pid)
    headers = dev.device()
    res = dev.check(headers, formats="mock-v1,dbc-v1")
    assert res["update_available"]
    p = res["patch"]
    assert p["artifact_format"] == "dbc-v1" and p["signature"] is None and p["key_id"] is None
    assert p["sha256"] == hashlib.sha256(data).hexdigest() and p["size_bytes"] == len(data)
    assert p["sequence"] == 3 and p["patch_id"] == json.loads(data[12:12 + struct.unpack(">I", data[8:12])[0]])["patch_id"]
    assert p["download_url"] == art["url"] and p["expires_at"].startswith(iso(NOW + timedelta(days=30))[:10])
    assert "revocations" not in res  # no list uploaded yet

    # A client that does not list dbc-v1 never sees the patch nor the new fields.
    old = dev.check(headers, formats="mock-v1")
    assert old["update_available"] is False and old["patch"] is None and "revocations" not in old


def test_dbc_approvals_are_verified(client):
    dev = Dev(client)
    approver = ec.generate_private_key(ec.SECP256R1())
    acert = issue_cert(dev.root, dev.root_id, dev.app_id, approver, "approver-1", serial=2, roles=("approver",))
    module = os.urandom(500)
    manifest = dev.manifest(module)
    body = canonical(manifest)
    good = {"cert": acert, "sig": raw_sig(approver, APPROVAL_DOMAIN, body)}
    assert dev.upload(dev.new_patch(), dev.sign(manifest, module, approvals=[good])).status_code == 201
    bad = {"cert": acert, "sig": raw_sig(approver, APPROVAL_DOMAIN, body + b"x")}
    m2 = dev.manifest(module, sequence=2)
    expect(dev.upload(dev.new_patch(), dev.sign(m2, module, approvals=[bad])), 422, "bad_approval")


# ---- every rejection ---------------------------------------------------------------------


def test_dbc_rejects_bad_signature(client):
    dev = Dev(client)
    module = os.urandom(800)
    manifest = dev.manifest(module)
    data = bytearray(dev.sign(manifest, module))
    # Sign a different manifest, then put the original one back: signature no longer matches.
    other = dev.sign(dev.manifest(module, sequence=9), module)
    m_len = struct.unpack(">I", other[8:12])[0]
    sig_other = other[16 + m_len:16 + m_len + struct.unpack(">I", other[12 + m_len:16 + m_len])[0]]
    body = canonical(manifest)
    expect(dev.upload(dev.new_patch(), container(body, sig_other, module)), 422, "bad_signature")
    assert data  # the untouched file is valid
    assert dev.upload(dev.new_patch(), bytes(data)).status_code == 201


def test_dbc_rejects_uncertified_and_untrusted_keys(client):
    dev = Dev(client)
    module = os.urandom(300)
    expect(dev.upload(dev.new_patch(), dev.sign(dev.manifest(module), module, cert=None)), 422, "certificate_required")
    # Certificate issued by a root that is not registered for this app.
    rogue = ec.generate_private_key(ec.SECP256R1())
    rogue_cert = issue_cert(rogue, "rogue-root", dev.app_id, dev.signer, dev.signer_id, serial=1)
    expect(dev.upload(dev.new_patch(), dev.sign(dev.manifest(module), module, cert=rogue_cert)), 422, "untrusted_root")
    # Root registered but forged certificate signature.
    forged = json.loads(json.dumps(dev.cert))
    forged["body"]["roles"] = ["approver", "signer"]
    expect(dev.upload(dev.new_patch(), dev.sign(dev.manifest(module), module, cert=forged)), 422,
           "bad_certificate_signature")
    # Certificate does not allow signing.
    approver_only = issue_cert(dev.root, dev.root_id, dev.app_id, dev.signer, dev.signer_id, 5, roles=("approver",))
    expect(dev.upload(dev.new_patch(), dev.sign(dev.manifest(module), module, cert=approver_only)), 422, "wrong_role")
    # Certificate for another environment.
    staging = issue_cert(dev.root, dev.root_id, dev.app_id, dev.signer, dev.signer_id, 6, environment="staging")
    expect(dev.upload(dev.new_patch(), dev.sign(dev.manifest(module), module, cert=staging)), 422, "wrong_environment")
    # Expired certificate.
    old = issue_cert(dev.root, dev.root_id, dev.app_id, dev.signer, dev.signer_id, 7,
                     not_before=NOW - timedelta(days=10), not_after=NOW - timedelta(days=1))
    expect(dev.upload(dev.new_patch(), dev.sign(dev.manifest(module), module, cert=old)), 422, "expired_certificate")
    # Signed by a key other than the certified one.
    other = ec.generate_private_key(ec.SECP256R1())
    expect(dev.upload(dev.new_patch(), dev.sign(dev.manifest(module), module, key=other)), 422, "bad_signature")
    # Revoked root on the server: nothing under it is accepted any more.
    assert client.post(f"/v1/admin/apps/{dev.slug}/trust/roots/{dev.root_id}/revoke", headers=ADMIN).status_code == 200
    expect(dev.upload(dev.new_patch(), dev.patch_file()), 422, "untrusted_root")


def test_dbc_rejects_wrong_app_release_baseline_and_identity(client):
    dev = Dev(client)
    expect(dev.upload(dev.new_patch(), dev.patch_file(app_id=str(uuid.uuid4()))), 422, "wrong_app")
    expect(dev.upload(dev.new_patch(), dev.patch_file(release_id=str(uuid.uuid4()))), 422, "wrong_release")
    expect(dev.upload(dev.new_patch(), dev.patch_file(baseline_libapp_sha256="a" * 64)), 422, "wrong_baseline")
    expect(dev.upload(dev.new_patch(), dev.patch_file(host_interface={"sha256": "6" * 64, "host_packages": []})),
           422, "wrong_interface")
    tc = toolchain()
    tc["id"] = "f" * 64
    expect(dev.upload(dev.new_patch(), dev.patch_file(toolchain=tc)), 422, "bad_toolchain")
    # No base artifact for that arch on the server.
    r = dev.upload(dev.new_patch(), dev.patch_file(), arch="armeabi-v7a")
    assert r.status_code == 422 and "base armeabi-v7a artifact" in r.text


def test_dbc_rejects_revoked_serial_key_and_patch(client):
    dev = Dev(client)
    rl = revocation_list(dev.root, dev.root_id, dev.release_id, 1, serials=[1])
    assert dev.trust_post("revocations", files={"file": ("r.otp", io.BytesIO(rl))}).status_code == 201
    expect(dev.upload(dev.new_patch(), dev.patch_file()), 422, "revoked_certificate")

    # New cert (serial 2) for the same key works, until the key id is revoked.
    dev.cert = issue_cert(dev.root, dev.root_id, dev.app_id, dev.signer, dev.signer_id, serial=2)
    revoked_pid = str(uuid.uuid4())
    assert dev.upload(dev.new_patch(), dev.patch_file(sequence=1)).status_code == 201
    rl = revocation_list(dev.root, dev.root_id, dev.release_id, 2, patch_ids=[revoked_pid], serials=[1])
    assert dev.trust_post("revocations", files={"file": ("r.otp", io.BytesIO(rl))}).status_code == 201
    expect(dev.upload(dev.new_patch(), dev.patch_file(sequence=2, patch_id=revoked_pid)), 422, "revoked")
    rl = revocation_list(dev.root, dev.root_id, dev.release_id, 3, key_ids=[dev.signer_id])
    assert dev.trust_post("revocations", files={"file": ("r.otp", io.BytesIO(rl))}).status_code == 201
    expect(dev.upload(dev.new_patch(), dev.patch_file(sequence=3)), 422, "revoked_key")


def test_dbc_rejects_replayed_sequence_and_duplicate_patch_id(client):
    dev = Dev(client)
    first, second = dev.new_patch(), dev.new_patch()
    pid = str(uuid.uuid4())
    assert dev.upload(second, dev.patch_file(sequence=5, patch_id=pid)).status_code == 201
    # Same patch_id again (another server patch, or the same arch).
    third = dev.new_patch()
    expect(dev.upload(third, dev.patch_file(sequence=6, patch_id=pid)), 409, "duplicate_patch_id")
    # Patch #1 must stay below the sequence of the newer patch #2 (5).
    expect(dev.upload(first, dev.patch_file(sequence=5)), 409, "replay")
    expect(dev.upload(first, dev.patch_file(sequence=7)), 409, "replay")
    assert dev.upload(first, dev.patch_file(sequence=4)).status_code == 201
    expect(dev.upload(third, dev.patch_file(sequence=5)), 409, "replay")
    expect(dev.upload(third, dev.patch_file(sequence=1)), 409, "replay")
    assert dev.upload(third, dev.patch_file(sequence=6)).status_code == 201


def test_dbc_rejects_bad_containers(client):
    from app import dbc

    dev = Dev(client)
    good = dev.patch_file()
    expect(dev.upload(dev.new_patch(), good + b"\x00"), 422, "trailing_data")
    expect(dev.upload(dev.new_patch(), good[:-1]), 422, "wrong_size")
    expect(dev.upload(dev.new_patch(), b"OTAPRT01" + good[8:]), 422, "bad_magic")
    expect(dev.upload(dev.new_patch(), good[:20]), 422, "truncated")
    oversized = good + b"\x00" * (dbc.MAX_CONTAINER_BYTES + 1 - len(good))
    expect(dev.upload(dev.new_patch(), oversized), 413, "too_large")
    # Manifest with whitespace: not canonical (even though correctly signed).
    module = os.urandom(100)
    body = json.dumps(dev.manifest(module), sort_keys=True).encode()
    sig = canonical({"alg": "ES256", "key_id": dev.signer_id, "sig": raw_sig(dev.signer, MANIFEST_DOMAIN, body),
                     "cert": dev.cert})
    expect(dev.upload(dev.new_patch(), container(body, sig, module)), 422, "bad_manifest")
    # Unknown manifest field.
    expect(dev.upload(dev.new_patch(), dev.patch_file(extra="x")), 422, "bad_manifest")
    # Already expired patch.
    expect(dev.upload(dev.new_patch(), dev.patch_file(expires_at=iso(NOW - timedelta(hours=1)))), 422, "expired")


def test_dbc_patch_must_be_android_and_legacy_upload_still_signs(client):
    dev = Dev(client)
    r = client.post(f"/v1/admin/apps/{dev.slug}/releases", json={"platform": "ios", "version": "1.0.0+1"},
                    headers=ADMIN)
    ios_id = r.json()["id"]
    r = client.post(f"/v1/admin/releases/{ios_id}/patches", json={"artifact_format": "dbc-v1"}, headers=ADMIN)
    assert r.status_code == 422
    # The mock-v1 path is unchanged: the server still signs it.
    rel = make_release(client, "2.0.0+2", slug=dev.slug)
    out = make_patch(client, rel["id"], {"x": 1}, channel=None)
    assert out["artifacts"][0]["signature"] and out["artifacts"][0]["key_id"]


# ---- trust endpoints ---------------------------------------------------------------------


def test_trust_roots_certificates_and_state(client):
    dev = Dev(client)
    same = dev.trust_post("roots", json={"key_id": dev.root_id, "public_key": pub_b64(dev.root)})
    assert same.status_code == 200
    other = ec.generate_private_key(ec.SECP256R1())
    assert dev.trust_post("roots", json={"key_id": dev.root_id, "public_key": pub_b64(other)}).status_code == 409
    bad = dev.trust_post("roots", json={"key_id": "r2", "public_key": base64.b64encode(b"\x04" + b"\x01" * 64).decode()})
    expect(bad, 422, "bad_public_key")

    r = dev.trust_post("certificates", json=dev.cert)
    assert r.status_code == 201, r.text
    assert r.json()["serial"] == 1 and r.json()["roles"] == ["signer"]
    assert dev.trust_post("certificates", json=dev.cert).status_code == 200  # same again
    clash = issue_cert(dev.root, dev.root_id, dev.app_id, other, "signer-2", serial=1)
    expect(dev.trust_post("certificates", json=clash), 409, "duplicate_serial")
    wrong_app = issue_cert(dev.root, dev.root_id, str(uuid.uuid4()), other, "signer-2", serial=3)
    expect(dev.trust_post("certificates", json=wrong_app), 422, "wrong_app_key")
    forged = json.loads(json.dumps(clash))
    forged["body"]["serial"] = 4
    expect(dev.trust_post("certificates", json=forged), 422, "bad_certificate_signature")
    floaty = json.loads(json.dumps(clash))
    floaty["body"]["serial"] = 4.0
    expect(dev.trust_post("certificates", json=floaty), 422, "bad_certificate")

    # A container whose cert serial clashes with a registered, different certificate.
    dev.cert = issue_cert(dev.root, dev.root_id, dev.app_id, other, "signer-2", serial=1)
    module = os.urandom(64)
    data = dev.sign(dev.manifest(module, key_id="signer-2"), module, key=other, key_id="signer-2")
    expect(dev.upload(dev.new_patch(), data), 409, "cert_conflict")

    state = client.get(f"/v1/admin/apps/{dev.slug}/trust", headers=ADMIN).json()
    assert state["application_id"] == dev.app_id
    assert [r["key_id"] for r in state["roots"]] == [dev.root_id]
    assert [c["serial"] for c in state["certificates"]] == [1]
    assert client.get(f"/v1/admin/apps/{dev.slug}/trust").status_code == 401  # admin only

    # Revoked root: certificates under it are refused.
    assert client.post(f"/v1/admin/apps/{dev.app_id}/trust/roots/{dev.root_id}/revoke", headers=ADMIN).status_code == 200
    fresh = issue_cert(dev.root, dev.root_id, dev.app_id, other, "signer-3", serial=9)
    expect(dev.trust_post("certificates", json=fresh), 422, "untrusted_root")
    state = client.get(f"/v1/admin/apps/{dev.app_id}/trust", headers=ADMIN).json()
    assert state["roots"][0]["revoked_at"] is not None


def test_revocation_lists_upload_and_served_to_dbc_devices(client):
    dev = Dev(client)

    def up(data):
        return dev.trust_post("revocations", files={"file": ("r.otp", io.BytesIO(data))})

    rl1 = revocation_list(dev.root, dev.root_id, dev.release_id, 1)
    r = up(rl1)
    assert r.status_code == 201, r.text
    assert r.json()["sequence"] == 1 and r.json()["root_key_id"] == dev.root_id
    expect(up(revocation_list(dev.root, dev.root_id, dev.release_id, 1)), 409, "stale_sequence")
    rogue = ec.generate_private_key(ec.SECP256R1())
    expect(up(revocation_list(rogue, dev.root_id, dev.release_id, 2)), 422, "bad_signature")
    expect(up(revocation_list(rogue, "rogue", dev.release_id, 2)), 422, "untrusted_root")
    expect(up(revocation_list(dev.root, dev.root_id, str(uuid.uuid4()), 2)), 422, "wrong_release")
    expect(up(rl1 + b"x"), 422, "trailing_data")
    expect(up(b"x" * (256 * 1024 + 1)), 413, "too_large")

    pid = dev.new_patch()
    data = dev.patch_file()
    assert dev.upload(pid, data).status_code == 201
    dev.publish(pid)
    headers = dev.device()
    res = dev.check(headers)
    assert res["update_available"]
    assert res["revocations"] == {"sequence": 1, "release_id": dev.release_id,
                                  "data_base64": base64.b64encode(rl1).decode()}

    # Revoke the published patch: the newest list is served and the patch is no longer offered.
    patch_uuid = res["patch"]["patch_id"]
    rl2 = revocation_list(dev.root, dev.root_id, dev.release_id, 2, patch_ids=[patch_uuid])
    assert up(rl2).status_code == 201
    res = dev.check(headers)
    assert res["update_available"] is False
    assert base64.b64decode(res["revocations"]["data_base64"]) == rl2
    assert "revocations" not in dev.check(headers, formats="mock-v1")

    listed = client.get(f"/v1/admin/apps/{dev.slug}/trust", headers=ADMIN).json()["revocation_lists"]
    assert [x["sequence"] for x in listed] == [1, 2] and listed[1]["revoked_patch_ids"] == [patch_uuid]


def test_expired_dbc_patch_is_not_offered(client, monkeypatch):
    dev = Dev(client)
    pid = dev.new_patch()
    assert dev.upload(pid, dev.patch_file(expires_at=iso(NOW + timedelta(hours=1)))).status_code == 201
    dev.publish(pid)
    headers = dev.device()
    assert dev.check(headers)["update_available"]

    import app.updates as updates

    real = updates.datetime

    class Later(real):
        @classmethod
        def now(cls, tz=None):
            return real.now(tz) + timedelta(hours=2)

    monkeypatch.setattr(updates, "datetime", Later)
    assert dev.check(headers)["update_available"] is False


# ---- device registration by UUID ---------------------------------------------------------


def test_register_by_application_id(client):
    app = make_app(client)
    base = {"installation_id": "install-uuid-1", "platform": "android", "arch": ARCH, "release_version": "1.0.0+1"}
    by_slug = client.post("/v1/devices/register", json={**base, "app": "demo"})
    by_id = client.post("/v1/devices/register", json={**base, "application_id": app["id"]})
    both = client.post("/v1/devices/register", json={**base, "app": "demo", "application_id": app["id"]})
    assert by_slug.status_code == by_id.status_code == both.status_code == 200
    assert by_slug.json()["device_id"] == by_id.json()["device_id"] == both.json()["device_id"]
    make_app(client, slug="other")
    mismatch = client.post("/v1/devices/register", json={**base, "app": "other", "application_id": app["id"]})
    assert mismatch.status_code == 422
    assert client.post("/v1/devices/register", json=base).status_code == 422
    unknown = client.post("/v1/devices/register", json={**base, "application_id": str(uuid.uuid4())})
    assert unknown.status_code == 404
    assert client.post("/v1/devices/register", json={**base, "application_id": "not-a-uuid"}).status_code == 422


# ---- legacy responses unchanged ----------------------------------------------------------

LEGACY_TOP = {"update_available", "application_id", "release_id", "patch", "rollback_to_patch_number",
              "rolled_back_patch_numbers", "revoked_patch_numbers", "next_check_after_seconds"}
LEGACY_PATCH = {"id", "number", "artifact_format", "arch", "runtime_abi", "download_url", "base_artifact_sha256",
                "payload_sha256", "result_sha256", "size_bytes", "signature", "key_id"}


@pytest.mark.parametrize("formats", ["mock-v1", "mock-v1,dbc-v1"])
def test_legacy_update_check_shape_unchanged(client, formats):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"n": 1})
    r = client.post("/v1/devices/register", json={"app": "demo", "installation_id": "install-legacy",
                                                  "platform": "android", "arch": ARCH,
                                                  "release_version": "1.0.0+100"})
    headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
    res = client.get("/v1/updates/check", headers=headers, params={
        "platform": "android", "arch": ARCH, "release_version": "1.0.0+100", "supported_formats": formats}).json()
    assert set(res) == LEGACY_TOP
    assert set(res["patch"]) == LEGACY_PATCH
    assert isinstance(res["patch"]["signature"], str) and res["patch"]["key_id"]


# ---- migration 0004 ----------------------------------------------------------------------


def test_migration_0004_up_and_down(tmp_path):
    from alembic import command
    from alembic.config import Config
    from sqlalchemy import create_engine, inspect, text

    from app.migrate import BACKEND_DIR

    engine = create_engine(f"sqlite:///{tmp_path / 'mig.db'}")

    def run(fn, target):
        with engine.begin() as conn:
            cfg = Config(str(BACKEND_DIR / "alembic.ini"))
            cfg.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
            cfg.attributes["connection"] = conn
            fn(cfg, target)

    def columns(table):
        return {c["name"]: c for c in inspect(engine).get_columns(table)}

    run(command.upgrade, "0003")
    now = "2026-01-01 00:00:00"
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO applications (id, slug, name, distribution, aot_policy_approved, created_at) "
                          "VALUES ('a1', 'demo', 'Demo', 'enterprise', 0, :t)"), {"t": now})
        conn.execute(text("INSERT INTO releases (id, application_id, platform, version, flutter_version, "
                          "engine_revision, runtime_abi, fingerprint, created_at) "
                          "VALUES ('r1', 'a1', 'android', '1.0.0', '', '', 'ota-runtime-v1', '{}', :t)"), {"t": now})
        conn.execute(text("INSERT INTO patches (id, release_id, number, artifact_format, status, note, created_at) "
                          "VALUES ('p1', 'r1', 1, 'mock-v1', 'published', '', :t)"), {"t": now})
        conn.execute(text("INSERT INTO patch_artifacts (id, patch_id, arch, base_artifact_sha256, payload_sha256, "
                          "result_sha256, size_bytes, storage_key, signature, key_id) "
                          "VALUES ('pa1', 'p1', 'arm64-v8a', 'b', 'p', 'r', 1, 'patches/x', 'SIG', 'dev-1')"))

    run(command.upgrade, "head")
    tables = set(inspect(engine).get_table_names())
    assert {"trust_roots", "key_certificates", "revocation_lists"} <= tables
    cols = columns("patch_artifacts")
    assert {"manifest", "manifest_sha256", "manifest_patch_id", "sequence", "signer_key_id", "cert_serial",
            "expires_at"} <= set(cols)
    assert cols["signature"]["nullable"] and cols["key_id"]["nullable"]
    assert {"toolchain_id", "dart_revision", "bytecode_format", "interface_sha256", "trust_environment"} <= set(
        columns("releases"))
    with engine.begin() as conn:
        assert conn.execute(text("SELECT signature, key_id FROM patch_artifacts WHERE id='pa1'")).one() == ("SIG", "dev-1")
        conn.execute(text("INSERT INTO patches (id, release_id, number, artifact_format, status, note, created_at) "
                          "VALUES ('p2', 'r1', 2, 'dbc-v1', 'draft', '', :t)"), {"t": now})
        conn.execute(text("INSERT INTO patch_artifacts (id, patch_id, arch, base_artifact_sha256, payload_sha256, "
                          "result_sha256, size_bytes, storage_key, sequence) "
                          "VALUES ('pa2', 'p2', 'arm64-v8a', 'b', 'p', 'r', 1, 'patches/y', 7)"))
        conn.execute(text("INSERT INTO revocation_lists (id, application_id, release_id, sequence, data, created_at) "
                          "VALUES ('rl1', 'a1', 'r1', 1, :d, :t)"), {"d": b"OTAPRT02", "t": now})

    run(command.downgrade, "0003")
    tables = set(inspect(engine).get_table_names())
    assert not {"trust_roots", "key_certificates", "revocation_lists"} & tables
    cols = columns("patch_artifacts")
    assert "sequence" not in cols and not cols["signature"]["nullable"]
    assert "toolchain_id" not in columns("releases")
    with engine.begin() as conn:
        rows = dict(conn.execute(text("SELECT id, signature FROM patch_artifacts")).all())
        assert rows == {"pa1": "SIG", "pa2": ""}
        assert conn.execute(text("SELECT version_num FROM alembic_version")).scalar() == "0003"

    run(command.upgrade, "head")
    with engine.begin() as conn:
        assert conn.execute(text("SELECT version_num FROM alembic_version")).scalar() == "0004"
