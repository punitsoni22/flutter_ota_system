"""End-to-end rules from the plan's "Version and scale rules" table."""

import base64
import hashlib
import io
import json

from cryptography.hazmat.primitives.asymmetric import ec

from app.canonical import SignedFields
from app.signing import verify
from tests.conftest import ADMIN


def make_app(client, slug="demo", distribution="enterprise"):
    r = client.post("/v1/admin/apps", json={"slug": slug, "name": "Demo", "distribution": distribution}, headers=ADMIN)
    assert r.status_code == 201, r.text
    return r.json()


def make_release(client, version, slug="demo", platform="android"):
    r = client.post(f"/v1/admin/apps/{slug}/releases", json={"platform": platform, "version": version}, headers=ADMIN)
    assert r.status_code == 201, r.text
    return r.json()


def make_patch(client, release_id, payload: dict, channel="production", percent=100, fmt="mock-v1", arch="arm64-v8a"):
    r = client.post(f"/v1/admin/releases/{release_id}/patches", json={"artifact_format": fmt}, headers=ADMIN)
    assert r.status_code == 201, r.text
    patch = r.json()
    r = client.post(
        f"/v1/admin/patches/{patch['id']}/artifacts",
        data={"arch": arch},
        files={"file": ("p.json", io.BytesIO(json.dumps(payload).encode()))},
        headers=ADMIN,
    )
    assert r.status_code == 201, r.text
    if channel:
        r = client.post(f"/v1/admin/patches/{patch['id']}/publish", json={"channel": channel, "rollout_percent": percent}, headers=ADMIN)
        assert r.status_code == 200, r.text
    return r.json()


def register(client, installation_id, version, slug="demo", channel="production", arch="arm64-v8a"):
    r = client.post(
        "/v1/devices/register",
        json={"app": slug, "installation_id": installation_id, "platform": "android", "arch": arch,
              "release_version": version, "channel": channel},
    )
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def check(client, headers, version, current=0, channel="production", arch="arm64-v8a", failed=()):
    r = client.get(
        "/v1/updates/check",
        params={"platform": "android", "arch": arch, "release_version": version, "channel": channel,
                "current_patch_number": current, "supported_formats": "mock-v1",
                "failed_patch_ids": ",".join(failed)},
        headers=headers,
    )
    assert r.status_code == 200, r.text
    return r.json()


def test_patch_flow_version_isolation_and_latest_patch(client):
    make_app(client)
    r100 = make_release(client, "1.0.0+100")
    make_release(client, "1.1.0+110")
    for n in range(1, 5):
        make_patch(client, r100["id"], {"n": n})

    old = register(client, "install-0001", "1.0.0+100")
    res = check(client, old, "1.0.0+100", current=0)
    assert res["update_available"] and res["patch"]["number"] == 4  # straight to the latest

    # New install of 1.0.0 after patches exist also gets the latest.
    new = register(client, "install-0002", "1.0.0+100")
    assert check(client, new, "1.0.0+100")["patch"]["number"] == 4

    # Already on 4: nothing to do.
    assert not check(client, old, "1.0.0+100", current=4)["update_available"]

    # 1.1.0 never sees 1.0.0 patches.
    other = register(client, "install-0110", "1.1.0+110")
    res = check(client, other, "1.1.0+110")
    assert not res["update_available"] and res["patch"] is None

    # Unknown release: no update, no error.
    assert not check(client, other, "9.9.9+999")["update_available"]


def test_signature_verifies_with_published_public_key(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"hello": "world"})
    headers = register(client, "install-sig1", "1.0.0+100")
    patch = check(client, headers, "1.0.0+100")["patch"]

    key = client.get("/v1/admin/signing-key", headers=ADMIN).json()
    public_key = ec.EllipticCurvePublicKey.from_encoded_point(
        ec.SECP256R1(), base64.b64decode(key["uncompressed_point_base64"])
    )
    payload = client.get(patch["download_url"].replace("http://cdn.test", "")).content
    assert hashlib.sha256(payload).hexdigest() == patch["payload_sha256"]

    apps = client.get("/v1/admin/apps", headers=ADMIN).json()
    fields = SignedFields(
        application_id=apps[0]["id"], release_id=rel["id"], patch_number=patch["number"],
        platform="android", arch=patch["arch"], runtime_abi=patch["runtime_abi"],
        artifact_format=patch["artifact_format"], base_artifact_sha256=patch["base_artifact_sha256"],
        payload_sha256=patch["payload_sha256"], result_sha256=patch["result_sha256"],
        size_bytes=patch["size_bytes"],
    )
    assert verify(public_key, fields.message(), patch["signature"])
    # Same signature does not verify for another patch number (no cross-patch replay).
    tampered = SignedFields(**{**fields.__dict__, "patch_number": 99})
    assert not verify(public_key, tampered.message(), patch["signature"])


def test_channels_are_separate(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"x": 1}, channel="dev")
    dev = register(client, "install-dev1", "1.0.0+100", channel="dev")
    prod = register(client, "install-prd1", "1.0.0+100")
    assert check(client, dev, "1.0.0+100", channel="dev")["update_available"]
    assert not check(client, prod, "1.0.0+100")["update_available"]


def test_rollout_percentage_is_sticky(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    patch = make_patch(client, rel["id"], {"x": 1}, percent=10)
    devices = [register(client, f"install-{i:05d}", "1.0.0+100") for i in range(400)]
    got_10 = {i for i, d in enumerate(devices) if check(client, d, "1.0.0+100")["update_available"]}
    assert 15 < len(got_10) < 70  # ~40 expected

    client.post(f"/v1/admin/patches/{patch['id']}/rollout", json={"channel": "production", "rollout_percent": 50}, headers=ADMIN)
    got_50 = {i for i, d in enumerate(devices) if check(client, d, "1.0.0+100")["update_available"]}
    assert got_10 <= got_50  # everyone from the 10% stays in
    assert 150 < len(got_50) < 250


def test_rollback_and_revoke_signals(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"n": 1})
    make_patch(client, rel["id"], {"n": 2})
    p3 = make_patch(client, rel["id"], {"n": 3})
    d = register(client, "install-rb01", "1.0.0+100")

    client.post(f"/v1/admin/patches/{p3['id']}/rollback", headers=ADMIN)
    res = check(client, d, "1.0.0+100", current=3)
    assert res["rolled_back_patch_numbers"] == [3]
    assert res["rollback_to_patch_number"] == 2
    assert res["update_available"] and res["patch"]["number"] == 2  # older patch allowed: current is bad

    # Device on patch 2 is told nothing new, but still sees the bad list.
    res = check(client, d, "1.0.0+100", current=2)
    assert not res["update_available"] and res["rolled_back_patch_numbers"] == [3]

    # Revoke everything: devices go back to the store build (0).
    patches = client.get(f"/v1/admin/releases/{rel['id']}/patches", headers=ADMIN).json()
    for p in patches:
        if p["status"] != "revoked":
            client.post(f"/v1/admin/patches/{p['id']}/revoke", headers=ADMIN)
    res = check(client, d, "1.0.0+100", current=2)
    assert res["rollback_to_patch_number"] == 0 and not res["update_available"]
    assert res["revoked_patch_numbers"] == [1, 2, 3]

    # Rolled-back patch can be published again; revoked cannot.
    r = client.post(f"/v1/admin/patches/{p3['id']}/publish", json={"channel": "production", "rollout_percent": 100}, headers=ADMIN)
    assert r.status_code == 409


def test_patch_that_crashed_on_device_is_skipped(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"n": 1})
    make_patch(client, rel["id"], {"n": 2})
    p3 = make_patch(client, rel["id"], {"n": 3})
    p4 = make_patch(client, rel["id"], {"crash": True})  # crashed here, still published
    d = register(client, "install-cr01", "1.0.0+100")

    # On patch 3, 4 crashed: nothing to offer (not 4 again).
    res = check(client, d, "1.0.0+100", current=3, failed=[p4["id"]])
    assert not res["update_available"]

    # Patch 3 rolled back: the device goes to 2, not to the store build.
    client.post(f"/v1/admin/patches/{p3['id']}/rollback", headers=ADMIN)
    res = check(client, d, "1.0.0+100", current=3, failed=[p4["id"]])
    assert res["rollback_to_patch_number"] == 2
    assert res["update_available"] and res["patch"]["number"] == 2

    # Other devices still get 4.
    assert check(client, register(client, "install-cr02", "1.0.0+100"), "1.0.0+100")["patch"]["number"] == 4


def test_no_downgrade_without_rollback(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"n": 1})
    make_patch(client, rel["id"], {"n": 2}, channel=None)  # draft, not published
    d = register(client, "install-nd01", "1.0.0+100")
    # Device claims patch 2 (e.g. from staging). Patch 1 must not be pushed over it.
    assert not check(client, d, "1.0.0+100", current=2)["update_available"]


def test_arch_must_match(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"n": 1}, arch="arm64-v8a")
    d = register(client, "install-arm7", "1.0.0+100", arch="armeabi-v7a")
    assert not check(client, d, "1.0.0+100", arch="armeabi-v7a")["update_available"]


def test_policy_gate_for_public_store_aot(client):
    make_app(client, distribution="public_store")
    rel = make_release(client, "1.0.0+100")
    client.post(
        f"/v1/admin/releases/{rel['id']}/artifacts", data={"arch": "arm64-v8a"},
        files={"file": ("libapp.so", io.BytesIO(b"base-bytes"))}, headers=ADMIN,
    )
    r = client.post(f"/v1/admin/releases/{rel['id']}/patches", json={"artifact_format": "aot-bidiff-android-v1"}, headers=ADMIN)
    patch = r.json()
    # AOT patch needs result_sha256.
    r = client.post(f"/v1/admin/patches/{patch['id']}/artifacts", data={"arch": "arm64-v8a"},
                    files={"file": ("d", io.BytesIO(b"diff"))}, headers=ADMIN)
    assert r.status_code == 422
    r = client.post(f"/v1/admin/patches/{patch['id']}/artifacts", data={"arch": "arm64-v8a", "result_sha256": "d" * 64},
                    files={"file": ("d", io.BytesIO(b"diff"))}, headers=ADMIN)
    assert r.status_code == 201
    assert r.json()["artifacts"][0]["base_artifact_sha256"] == hashlib.sha256(b"base-bytes").hexdigest()

    publish = {"channel": "production", "rollout_percent": 100}
    r = client.post(f"/v1/admin/patches/{patch['id']}/publish", json=publish, headers=ADMIN)
    assert r.status_code == 403 and "policy_review_required" in r.text

    client.post("/v1/admin/apps/demo/policy-approval", json={"approved": True, "reason": "legal ok 2026-11"}, headers=ADMIN)
    assert client.post(f"/v1/admin/patches/{patch['id']}/publish", json=publish, headers=ADMIN).status_code == 200


def test_events_are_counted(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    patch = make_patch(client, rel["id"], {"n": 1})
    d = register(client, "install-ev01", "1.0.0+100")
    events = [{"type": "patch_boot_succeeded", "patch_id": patch["id"]}] * 3 + [
        {"type": "patch_boot_failed", "patch_id": patch["id"]}
    ]
    assert client.post("/v1/events/batch", json={"events": events}, headers=d).status_code == 202
    counts = client.get(f"/v1/admin/patches/{patch['id']}", headers=ADMIN).json()["event_counts"]
    assert counts == {"patch_boot_succeeded": 3, "patch_boot_failed": 1}


def test_auth_required(client):
    assert client.get("/v1/admin/apps").status_code == 401
    assert client.get("/v1/updates/check", params={"platform": "android", "arch": "arm64-v8a", "release_version": "1"}).status_code == 401


def test_admin_page_and_device_summary(client):
    assert client.get("/admin").headers["content-type"].startswith("text/html")
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    make_patch(client, rel["id"], {"n": 1})
    for i in range(3):
        check(client, register(client, f"install-sum{i}", "1.0.0+100"), "1.0.0+100", current=1 if i else 0)
    r = client.get("/v1/admin/apps/demo/devices/summary", headers=ADMIN)
    assert r.status_code == 200
    counts = {row["patch_number"]: row["devices"] for row in r.json()}
    assert counts == {0: 1, 1: 2}
    assert client.get("/v1/admin/apps/demo/devices/summary").status_code == 401


def test_staging_then_promote_to_production(client):
    make_app(client)
    rel = make_release(client, "1.0.0+100")
    p1 = make_patch(client, rel["id"], {"n": 1})
    p2 = make_patch(client, rel["id"], {"n": 2}, channel="staging")
    prod = register(client, "install-pr01", "1.0.0+100")
    tester = register(client, "install-st01", "1.0.0+100", channel="staging")

    # Patch 2 is only on staging: production keeps patch 1, the tester gets 2.
    assert check(client, prod, "1.0.0+100")["patch"]["number"] == 1
    assert check(client, tester, "1.0.0+100", channel="staging")["patch"]["number"] == 2

    # Promote the same patch: no rebuild, same signed file, both channels listed.
    r = client.post(f"/v1/admin/patches/{p2['id']}/rollout", json={"channel": "production", "rollout_percent": 100}, headers=ADMIN)
    assert r.status_code == 200
    assert {d["channel"] for d in r.json()["deployments"]} == {"staging", "production"}
    res = check(client, prod, "1.0.0+100", current=1)
    assert res["patch"]["number"] == 2 and res["patch"]["id"] == p2["id"]
    assert p1["id"] != p2["id"]


def test_code_patch_release_keeps_base_private(client):
    make_app(client, slug="code")
    r = client.post(
        "/v1/admin/apps/code/releases",
        json={"platform": "android", "version": "2.0.0+5", "runtime_abi": "ota-aot-android-1",
              "fingerprint": {"kind": "apk", "flutter": {"frameworkVersion": "3.47.5"}}},
        headers=ADMIN,
    )
    assert r.status_code == 201, r.text
    release = r.json()
    assert release["fingerprint"]["kind"] == "apk"
    base = b"\x7fELF base libapp"
    r = client.post(f"/v1/admin/releases/{release['id']}/artifacts", data={"arch": "x86_64"},
                    files={"file": ("libapp.so", io.BytesIO(base))}, headers=ADMIN)
    assert r.status_code == 201, r.text
    url = r.json()["artifacts"][0]["url"]
    assert url.startswith("/v1/admin/")

    assert client.get(url).status_code == 401, "admin key required"
    assert client.get(url, headers=ADMIN).content == base
    sha = hashlib.sha256(base).hexdigest()
    assert client.get(f"/cdn/releases/{sha}").status_code == 404, "never on the CDN"

    listed = client.get("/v1/admin/apps/code/releases", headers=ADMIN).json()
    assert listed[0]["fingerprint"]["flutter"]["frameworkVersion"] == "3.47.5"


def test_delete_release_only_without_live_patches(client):
    make_app(client)
    rel = make_release(client, "1.0.0+1")
    patch = make_patch(client, rel["id"], {"a": 1})
    assert client.delete(f"/v1/admin/releases/{rel['id']}", headers=ADMIN).status_code == 409
    client.post(f"/v1/admin/patches/{patch['id']}/rollback", headers=ADMIN)
    assert client.delete(f"/v1/admin/releases/{rel['id']}", headers=ADMIN).status_code == 204
    assert client.get("/v1/admin/apps/demo/releases", headers=ADMIN).json() == []
    make_release(client, "1.0.0+1")  # the version can be registered again
