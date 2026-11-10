from functools import lru_cache

from app.config import get_settings
from app.signing import LocalSigner, Signer
from app.storage import LocalStorage, S3Storage, Storage


@lru_cache
def get_storage() -> Storage:
    s = get_settings()
    if s.storage_backend == "s3":
        return S3Storage(
            endpoint_url=s.s3_endpoint_url,
            region=s.s3_region,
            access_key_id=s.s3_access_key_id,
            secret_access_key=s.s3_secret_access_key,
            session_token=s.s3_session_token,
            public_bucket=s.s3_public_bucket,
            private_bucket=s.s3_private_bucket,
            public_base_url=s.cdn_base_url,
        )
    return LocalStorage(s.storage_dir, s.cdn_base_url)


@lru_cache
def get_signer() -> Signer:
    s = get_settings()
    if s.signing_key_pem:
        return LocalSigner.from_pem(s.signing_key_pem.encode(), s.signing_key_id)
    return LocalSigner.from_file(s.signing_key_path, s.signing_key_id, s.auto_generate_signing_key)
