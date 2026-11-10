import hashlib
import io

import boto3
from moto import mock_aws

from app.signing import LocalSigner
from app.storage import S3Storage


@mock_aws
def test_s3_storage_keeps_patches_public_and_releases_private():
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket="pub")
    s3.create_bucket(Bucket="priv")
    storage = S3Storage(
        endpoint_url="", region="us-east-1", access_key_id="k", secret_access_key="s",
        public_bucket="pub", private_bucket="priv", public_base_url="https://cdn.test/", client=s3,
    )

    patch = storage.put(io.BytesIO(b"diff"), "patches")
    assert patch.sha256 == hashlib.sha256(b"diff").hexdigest() and patch.size_bytes == 4
    assert s3.get_object(Bucket="pub", Key=patch.storage_key)["Body"].read() == b"diff"
    assert storage.url(patch.storage_key) == f"https://cdn.test/patches/{patch.sha256}"

    release = storage.put(io.BytesIO(b"libapp"), "releases")
    assert s3.list_objects_v2(Bucket="pub", Prefix="releases/").get("KeyCount") == 0
    assert b"".join(storage.read(release.storage_key)) == b"libapp"

    again = storage.put(io.BytesIO(b"diff"), "patches")  # same bytes: stored once
    assert again == patch


def test_signing_key_from_one_line_secret():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    one_line = pem.decode().strip().replace("\n", "\\n").encode()  # how it sits in an env var
    assert LocalSigner.from_pem(one_line, "k1").key_id == "k1"
