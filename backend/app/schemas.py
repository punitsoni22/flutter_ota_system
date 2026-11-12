# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

import json
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Platform = Literal["android", "ios"]
ArtifactFormat = Literal["mock-v1", "aot-bidiff-android-v1", "evc-v1", "dbc-v1"]
SLUG = r"^[a-z0-9][a-z0-9-]{1,98}[a-z0-9]$"
ARCH = r"^[a-z0-9_-]{2,32}$"
# Lowercase UUID as written in dbc-v1 manifests (versions 1-8).
UUID_PATTERN = r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
SHA256_PATTERN = r"^[0-9a-f]{64}$"
KEY_ID_PATTERN = r"^[A-Za-z0-9._-]{1,64}$"


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
    # Latest policy approval or withdrawal (KI-2); null if never set.
    policy_reason: str | None = None
    policy_updated_at: datetime | None = None
    created_at: datetime


class PolicyApproval(BaseModel):
    approved: bool
    reason: str = Field(min_length=3, max_length=1000)


class PolicyApprovalOut(ORM):
    approved: bool
    reason: str
    created_at: datetime


class ReleaseCreate(BaseModel):
    platform: Platform
    version: str = Field(min_length=1, max_length=64, description='Store version, e.g. "1.0.0+100"')
    flutter_version: str = ""
    engine_revision: str = ""
    runtime_abi: str = Field(default="ota-runtime-v1", max_length=64)
    # Written by `ota release android`; read back by `ota patch android` (see models.Release).
    fingerprint: dict = Field(default_factory=dict)
    # Register a version again although devices still report it from a deleted release (KI-1).
    replace: bool = False
    # Phase 4 (dbc-v1), all optional. `id` lets the developer CLI choose the release id before the
    # build, because it is compiled into the app and written into manifests as release_id.
    id: str | None = Field(default=None, pattern=UUID_PATTERN)
    toolchain_id: str | None = Field(default=None, pattern=SHA256_PATTERN)
    dart_revision: str | None = Field(default=None, pattern=r"^[0-9A-Za-z.+-]{1,64}$")
    bytecode_format: int | None = Field(default=None, ge=1, le=1000)
    interface_sha256: str | None = Field(default=None, pattern=SHA256_PATTERN)
    trust_environment: str | None = Field(default=None, pattern=KEY_ID_PATTERN)

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
    toolchain_id: str | None = None
    dart_revision: str | None = None
    bytecode_format: int | None = None
    interface_sha256: str | None = None
    trust_environment: str | None = None
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
    # Null for dbc-v1 (developer-signed; the signature is inside the container).
    signature: str | None
    key_id: str | None
    url: str = ""
    # dbc-v1 only.
    manifest_patch_id: str | None = None
    sequence: int | None = None
    signer_key_id: str | None = None
    cert_serial: int | None = None
    expires_at: datetime | None = None


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
    # Skip the promotion checks of a protected channel (KI-4). Needs a reason; it is logged.
    force: bool = False
    reason: str | None = Field(default=None, max_length=1000)


# ---- devices -----------------------------------------------------------------------------


class DeviceRegister(BaseModel):
    # One of the two is required. If both are sent they must name the same application.
    app: str | None = Field(default=None, pattern=SLUG, description="Application slug")
    application_id: str | None = Field(default=None, pattern=UUID_PATTERN, description="Application id (UUID)")
    installation_id: str = Field(min_length=8, max_length=128)
    platform: Platform
    arch: str = Field(pattern=ARCH)
    release_version: str = Field(min_length=1, max_length=64)
    channel: str = Field(default="production", max_length=64)

    @model_validator(mode="after")
    def _app_or_id(self):
        if self.app is None and self.application_id is None:
            raise ValueError("send app (slug) or application_id (UUID)")
        return self


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
    # Null for dbc-v1: the device verifies the developer signature inside the container.
    signature: str | None
    key_id: str | None
    # dbc-v1 only (left out of the JSON for other formats).
    sha256: str | None = None
    patch_id: str | None = None
    sequence: int | None = None
    expires_at: datetime | None = None


class RevocationsOut(BaseModel):
    """The newest root-signed revocation list for the device's release, byte for byte."""

    sequence: int
    release_id: str
    data_base64: str


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
    # Only for devices that list dbc-v1 in supported_formats (left out of the JSON otherwise).
    revocations: RevocationsOut | None = None


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


# ---- developer signing trust (dbc-v1) ----------------------------------------------------


class TrustRootCreate(BaseModel):
    key_id: str = Field(pattern=KEY_ID_PATTERN)
    public_key: str = Field(min_length=80, max_length=120, description="Base64 uncompressed P-256 point")


class TrustRootOut(ORM):
    key_id: str
    public_key: str
    created_at: datetime
    revoked_at: datetime | None = None


class CertificateOut(BaseModel):
    serial: int
    key_id: str
    roles: list[str]
    environment: str
    not_before: datetime
    not_after: datetime
    root_key_id: str
    certificate: dict


class RevocationListOut(BaseModel):
    sequence: int
    release_id: str | None
    root_key_id: str
    revoked_patch_ids: list[str]
    revoked_key_ids: list[str]
    revoked_cert_serials: list[int]
    created_at: datetime


class TrustStateOut(BaseModel):
    application_id: str
    roots: list[TrustRootOut]
    certificates: list[CertificateOut]
    revocation_lists: list[RevocationListOut]
