# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

import hashlib

from app.bucket import rollout_bucket
from app.canonical import SignedFields
from app.signing import LocalSigner, verify


def test_canonical_message_matches_adr_0002_test_vector():
    message = SignedFields(
        application_id="6f629161-5d63-4caa-9174-0ad1b225ad37",
        release_id="7b831760-d896-433e-a4d2-825234657044",
        patch_number=3,
        platform="android",
        arch="arm64-v8a",
        runtime_abi="ota-runtime-v1",
        artifact_format="mock-v1",
        base_artifact_sha256="a" * 64,
        payload_sha256="b" * 64,
        result_sha256="c" * 64,
        size_bytes=1834241,
    ).message()
    assert len(message) == 371
    assert (
        hashlib.sha256(message).hexdigest()
        == "2c53f97238a44c3bc7262a54e8c7ecd8e9ea105aa0b3c4fdc105fe38e78a8a79"
    )


def test_sign_and_verify_roundtrip(tmp_path):
    signer = LocalSigner.from_file(tmp_path / "k.pem", "k1", generate=True)
    sig = signer.sign(b"hello")
    assert verify(signer.public_key(), b"hello", sig)
    assert not verify(signer.public_key(), b"hellO", sig)


def test_bucket_is_deterministic_and_roughly_uniform():
    a = rollout_bucket("s", "app", "install-1", "patch")
    assert a == rollout_bucket("s", "app", "install-1", "patch")
    buckets = [rollout_bucket("s", "app", f"install-{i}", "patch") for i in range(20_000)]
    in_10_percent = sum(b < 1000 for b in buckets) / len(buckets)
    assert 0.09 < in_10_percent < 0.11


def test_production_settings_refuse_dev_defaults():
    from app.config import Settings

    problems = Settings(env="production").production_problems()
    assert any("ADMIN_API_KEY" in p for p in problems)
    assert any("AUTO_GENERATE" in p for p in problems)
    good = Settings(
        env="production",
        admin_api_key="a" * 40,
        device_jwt_secret="b" * 40,
        rollout_hmac_secret="c" * 40,
        auto_generate_signing_key=False,
        cdn_base_url="https://ota.example.com/cdn",
        database_url="postgresql+psycopg://u:p@db/ota",
        serve_artifacts_locally=False,
    )
    assert good.production_problems() == []
