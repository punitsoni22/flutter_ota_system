"""Content-addressed file storage. Files are named by their SHA-256 and never overwritten.

Two kinds of file, kept apart:
  patches/<sha>   signed diffs, public: devices download them from a CDN or public bucket.
  releases/<sha>  store builds (the app's whole compiled code), private: admin API only.

LocalStorage keeps both on disk (Docker on a VPS; nginx serves patches/). S3Storage keeps them in
two buckets of any S3-compatible service (Supabase Storage, Cloudflare R2, AWS S3), for hosts
without a lasting disk.
"""

import hashlib
import os
import tempfile
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Protocol


@dataclass(frozen=True)
class StoredFile:
    storage_key: str
    sha256: str
    size_bytes: int


class Storage(Protocol):
    def put(self, stream: BinaryIO, kind: str) -> StoredFile: ...

    def read(self, storage_key: str) -> Iterator[bytes]: ...

    def url(self, storage_key: str) -> str: ...


def _hash_to_temp(stream: BinaryIO, directory: Path | None) -> tuple[str, str, int]:
    """Copy the upload to a temp file while hashing it: (temp path, sha256, size)."""
    digest = hashlib.sha256()
    size = 0
    fd, tmp_name = tempfile.mkstemp(dir=directory, prefix=".upload-")
    try:
        with os.fdopen(fd, "wb") as out:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
                out.write(chunk)
    except BaseException:
        os.unlink(tmp_name)
        raise
    return tmp_name, digest.hexdigest(), size


def _chunks(path: Path) -> Iterator[bytes]:
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            yield chunk


class LocalStorage:
    def __init__(self, root: Path, public_base_url: str):
        self.root = root
        self.public_base_url = public_base_url.rstrip("/")
        self.root.mkdir(parents=True, exist_ok=True)

    def put(self, stream: BinaryIO, kind: str) -> StoredFile:
        tmp_name, sha, size = _hash_to_temp(stream, self.root)
        try:
            key = f"{kind}/{sha}"
            target = self.root / key
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                os.unlink(tmp_name)  # Same bytes already stored: immutable, keep the original.
            else:
                os.chmod(tmp_name, 0o644)  # mkstemp creates 0600; the CDN must be able to read it.
                os.replace(tmp_name, target)
            return StoredFile(storage_key=key, sha256=sha, size_bytes=size)
        except BaseException:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
            raise

    def read(self, storage_key: str) -> Iterator[bytes]:
        return _chunks(self.root / storage_key)

    def url(self, storage_key: str) -> str:
        return f"{self.public_base_url}/{storage_key}"


class S3Storage:
    """patches/ in a public bucket, releases/ in a private one. public_base_url serves the public
    bucket, e.g. https://<ref>.supabase.co/storage/v1/object/public/ota-public or https://pub-….r2.dev
    """

    def __init__(
        self,
        *,
        endpoint_url: str,
        region: str,
        access_key_id: str,
        secret_access_key: str,
        session_token: str = "",
        public_bucket: str,
        private_bucket: str,
        public_base_url: str,
        client=None,
    ):
        if client is None:
            import boto3
            from botocore.config import Config

            client = boto3.client(
                "s3",
                endpoint_url=endpoint_url or None,
                region_name=region,
                aws_access_key_id=access_key_id,
                aws_secret_access_key=secret_access_key,
                aws_session_token=session_token or None,
                # Supabase needs path-style URLs; R2 and AWS accept them too.
                config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
            )
        self._s3 = client
        self.public_bucket = public_bucket
        self.private_bucket = private_bucket
        self.public_base_url = public_base_url.rstrip("/")

    def _bucket(self, storage_key: str) -> str:
        return self.public_bucket if storage_key.startswith("patches/") else self.private_bucket

    def _exists(self, bucket: str, key: str) -> bool:
        from botocore.exceptions import ClientError

        try:
            self._s3.head_object(Bucket=bucket, Key=key)
            return True
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
                return False
            raise

    def put(self, stream: BinaryIO, kind: str) -> StoredFile:
        tmp_name, sha, size = _hash_to_temp(stream, None)
        try:
            key = f"{kind}/{sha}"
            bucket = self._bucket(key)
            if not self._exists(bucket, key):
                self._s3.upload_file(
                    tmp_name,
                    bucket,
                    key,
                    ExtraArgs={
                        "ContentType": "application/octet-stream",
                        "CacheControl": "public, max-age=31536000, immutable",
                    },
                )
            return StoredFile(storage_key=key, sha256=sha, size_bytes=size)
        finally:
            os.unlink(tmp_name)

    def read(self, storage_key: str) -> Iterator[bytes]:
        body = self._s3.get_object(Bucket=self._bucket(storage_key), Key=storage_key)["Body"]
        return body.iter_chunks(1024 * 1024)

    def url(self, storage_key: str) -> str:
        return f"{self.public_base_url}/{storage_key}"
