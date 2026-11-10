from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parents[1]


class Settings(BaseSettings):
    """All settings come from environment variables prefixed with OTA_."""

    model_config = SettingsConfigDict(env_prefix="OTA_", env_file=".env", extra="ignore")

    # SQLite is for local runs and tests. Docker Compose sets a Postgres URL.
    database_url: str = f"sqlite:///{BACKEND_DIR / 'data' / 'ota.db'}"

    # Admin API (CLI / CI). Replaced by Entra ID in Phase 8.
    admin_api_key: str = "dev-admin-key"

    # Device tokens.
    device_jwt_secret: str = "dev-device-jwt-secret-change-me"
    device_token_ttl_seconds: int = 30 * 24 * 3600

    # Rollout buckets (ADR-0004). Changing it reshuffles every cohort.
    rollout_hmac_secret: str = "dev-rollout-secret-change-me"

    # Patch files. The API writes here; a CDN (nginx locally) serves it.
    storage_dir: Path = BACKEND_DIR / "data" / "artifacts"
    cdn_base_url: str = "http://127.0.0.1:8000/cdn"
    # Serve storage_dir at /cdn from FastAPI itself (local runs without nginx only).
    serve_artifacts_locally: bool = True

    # "local": files on disk (storage_dir). "s3": two buckets on Supabase Storage / Cloudflare R2 /
    # AWS, for hosts without a lasting disk (see storage.py). cdn_base_url = the public bucket's URL.
    storage_backend: Literal["local", "s3"] = "local"
    s3_endpoint_url: str = ""
    s3_region: str = "auto"
    s3_access_key_id: str = ""
    s3_secret_access_key: str = ""
    # Supabase without dashboard S3 keys: key id = project ref, secret = anon key, token = service_role key.
    s3_session_token: str = ""
    s3_public_bucket: str = "ota-public"
    s3_private_bucket: str = "ota-private"

    # Connections per worker. Free Postgres poolers allow few: use 3 there.
    db_pool_size: int = 10

    # ES256 signing key (ADR-0002): the PEM itself (hosts without a disk), else the file.
    signing_key_pem: str = ""
    signing_key_path: Path = BACKEND_DIR / "data" / "keys" / "ota_signing_private.pem"
    signing_key_id: str = "dev-1"
    # Create a dev key on startup if none exists. Must be false in production.
    auto_generate_signing_key: bool = True

    # Client polling hints (with jitter applied on the device).
    check_interval_seconds: int = 1800

    # "production" turns on the startup checks in production_problems().
    env: str = "development"

    def production_problems(self) -> list[str]:
        """Settings that are fine on a laptop and dangerous on a server."""
        problems = []
        defaults = Settings.model_fields
        for name in ("admin_api_key", "device_jwt_secret", "rollout_hmac_secret"):
            value = getattr(self, name)
            if value == defaults[name].default or len(value) < 32:
                problems.append(f"OTA_{name.upper()} must be set to a random value of 32+ characters")
        if self.auto_generate_signing_key and not self.signing_key_pem:
            problems.append("OTA_AUTO_GENERATE_SIGNING_KEY must be false (create the key once: python -m app.keygen)")
        if self.storage_backend == "s3" and not (self.s3_access_key_id and self.s3_secret_access_key):
            problems.append("OTA_S3_ACCESS_KEY_ID and OTA_S3_SECRET_ACCESS_KEY must be set")
        if not self.cdn_base_url.startswith("https://"):
            problems.append("OTA_CDN_BASE_URL must be https://")
        if self.database_url.startswith("sqlite"):
            problems.append("OTA_DATABASE_URL must point at Postgres")
        if self.serve_artifacts_locally and self.storage_backend == "local":
            problems.append("OTA_SERVE_ARTIFACTS_LOCALLY must be false (the CDN serves patches)")
        return problems


@lru_cache
def get_settings() -> Settings:
    return Settings()
