import json
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

Platform = Literal["android", "ios"]
ArtifactFormat = Literal["mock-v1", "aot-bidiff-android-v1", "evc-v1"]
SLUG = r"^[a-z0-9][a-z0-9-]{1,98}[a-z0-9]$"
ARCH = r"^[a-z0-9_-]{2,32}$"


class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ---- admin -------------------------------------------------------------------------------


class AppCreate(BaseModel):
    slug: str = Field(pattern=SLUG)
    name: str = Field(min_length=1, max_length=200)
    distribution: Literal["public_store", "enterprise"] = "enterprise"


class AppOut(ORM):
    id: str
    slug: str
    name: str
    distribution: str
    aot_policy_approved: bool
    created_at: datetime


class PolicyApproval(BaseModel):
    approved: bool
    reason: str = Field(min_length=3, max_length=1000)


class ReleaseCreate(BaseModel):
    platform: Platform
    version: str = Field(min_length=1, max_length=64, description='Store version, e.g. "1.0.0+100"')
    flutter_version: str = ""
    engine_revision: str = ""
    runtime_abi: str = Field(default="ota-runtime-v1", max_length=64)
    # Written by `ota release android`; read back by `ota patch android` (see models.Release).
    fingerprint: dict = Field(default_factory=dict)

    @field_validator("fingerprint")
    @classmethod
    def _small_fingerprint(cls, value: dict) -> dict:
        if len(json.dumps(value)) > 256_000:
            raise ValueError("fingerprint is too large")
        return value


class ReleaseArtifactOut(ORM):
    arch: str
    sha256: str
    size_bytes: int
    url: str = ""


class ReleaseOut(ORM):
    id: str
    application_id: str
    platform: str
    version: str
    flutter_version: str
    engine_revision: str
    runtime_abi: str
    fingerprint: dict = {}
    created_at: datetime
    artifacts: list[ReleaseArtifactOut] = []

    @field_validator("fingerprint", mode="before")
    @classmethod
    def _parse_fingerprint(cls, value):
        return json.loads(value or "{}") if isinstance(value, str) else value


class PatchCreate(BaseModel):
    artifact_format: ArtifactFormat = "mock-v1"
    note: str = Field(default="", max_length=2000)


class PatchArtifactOut(ORM):
    arch: str
    base_artifact_sha256: str
    payload_sha256: str
    result_sha256: str
    size_bytes: int
    signature: str
    key_id: str
    url: str = ""


class DeploymentOut(BaseModel):
    channel: str
    rollout_percent: float


class PatchOut(BaseModel):
    id: str
    release_id: str
    release_version: str = ""
    platform: str = ""
    number: int
    artifact_format: str
    status: str
    note: str
    created_at: datetime
    artifacts: list[PatchArtifactOut] = []
    deployments: list[DeploymentOut] = []
    event_counts: dict[str, int] = {}


class RolloutRequest(BaseModel):
    channel: str = Field(min_length=1, max_length=64)
    rollout_percent: float = Field(ge=0, le=100)


# ---- devices -----------------------------------------------------------------------------


class DeviceRegister(BaseModel):
    app: str = Field(pattern=SLUG, description="Application slug")
    installation_id: str = Field(min_length=8, max_length=128)
    platform: Platform
    arch: str = Field(pattern=ARCH)
    release_version: str = Field(min_length=1, max_length=64)
    channel: str = Field(default="production", max_length=64)


class DeviceRegisterOut(BaseModel):
    device_id: str
    access_token: str
    expires_in: int


class UpdatePatch(BaseModel):
    id: str
    number: int
    artifact_format: str
    arch: str
    runtime_abi: str
    download_url: str
    base_artifact_sha256: str
    payload_sha256: str
    result_sha256: str
    size_bytes: int
    signature: str
    key_id: str


class UpdateCheckOut(BaseModel):
    """Every response carries the bad-patch lists, even with no update (ADR-0005)."""

    update_available: bool
    application_id: str
    release_id: str | None
    patch: UpdatePatch | None = None
    # If set, the device's current patch is bad: switch to this number (0 = store build).
    rollback_to_patch_number: int | None = None
    rolled_back_patch_numbers: list[int] = []
    revoked_patch_numbers: list[int] = []
    next_check_after_seconds: int


class DeviceEvent(BaseModel):
    type: Literal[
        "patch_downloaded",
        "patch_hash_failed",
        "patch_signature_failed",
        "patch_staged",
        "patch_boot_succeeded",
        "patch_boot_failed",
        "patch_auto_rollback",
    ]
    patch_id: str = Field(min_length=36, max_length=36)


class EventBatch(BaseModel):
    events: list[DeviceEvent] = Field(max_length=100)
