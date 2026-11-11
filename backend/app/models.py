# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Database tables.

    Application ─┬─ Channel (dev / staging / production)
                 ├─ Release (one store build: platform + version) ─┬─ ReleaseArtifact (base file per arch)
                 │                                                └─ Patch (1, 2, 3… per release) ─┬─ PatchArtifact (per arch, signed)
                 │                                                                                 └─ PatchDeployment (channel + rollout %)
                 └─ Device (one app installation)

A patch belongs to exactly ONE release. That is the rule that stops 1.0.0 patches reaching 1.1.0.
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def new_id() -> str:
    return str(uuid.uuid4())


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    type_annotation_map = {datetime: DateTime(timezone=True)}


PLATFORMS = ("android", "ios")
ARTIFACT_FORMATS = ("mock-v1", "aot-bidiff-android-v1", "evc-v1")  # ADR-0003
AOT_FORMATS = ("aot-bidiff-android-v1",)
DEFAULT_CHANNELS = ("dev", "staging", "production")


class Application(Base):
    __tablename__ = "applications"
    __table_args__ = (
        CheckConstraint("distribution IN ('public_store', 'enterprise')", name="ck_app_distribution"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    slug: Mapped[str] = mapped_column(String(100), unique=True)
    name: Mapped[str] = mapped_column(String(200))
    distribution: Mapped[str] = mapped_column(String(20), default="enterprise")
    # ADR-0011: AOT patches to public store apps need a recorded policy approval.
    aot_policy_approved: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)

    channels: Mapped[list["Channel"]] = relationship(back_populates="application")
    policy_approvals: Mapped[list["PolicyApprovalRecord"]] = relationship(
        order_by="PolicyApprovalRecord.created_at.desc()", lazy="selectin"
    )

    # Latest approval/withdrawal, for AppOut (KI-2).
    @property
    def policy_reason(self) -> str | None:
        return self.policy_approvals[0].reason if self.policy_approvals else None

    @property
    def policy_updated_at(self) -> datetime | None:
        return self.policy_approvals[0].created_at if self.policy_approvals else None


class PolicyApprovalRecord(Base):
    """Every approval or withdrawal of AOT code patches for an app, with its reason (KI-2).

    There are no per-person admin identities yet, so who approved is not recorded.
    """

    __tablename__ = "policy_approvals"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    application_id: Mapped[str] = mapped_column(ForeignKey("applications.id"), index=True)
    approved: Mapped[bool] = mapped_column(Boolean)
    reason: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)


class Channel(Base):
    __tablename__ = "channels"
    __table_args__ = (UniqueConstraint("application_id", "name"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    application_id: Mapped[str] = mapped_column(ForeignKey("applications.id"), index=True)
    name: Mapped[str] = mapped_column(String(64))

    application: Mapped[Application] = relationship(back_populates="channels")


class Release(Base):
    __tablename__ = "releases"
    __table_args__ = (
        UniqueConstraint("application_id", "platform", "version"),
        CheckConstraint("platform IN ('android', 'ios')", name="ck_release_platform"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    application_id: Mapped[str] = mapped_column(ForeignKey("applications.id"), index=True)
    platform: Mapped[str] = mapped_column(String(16))
    # Full store version including build number, e.g. "1.0.0+100".
    version: Mapped[str] = mapped_column(String(64))
    flutter_version: Mapped[str] = mapped_column(String(64), default="")
    engine_revision: Mapped[str] = mapped_column(String(64), default="")
    # Which runtime the store build contains, e.g. "ota-runtime-v1" (mock) or "ota-engine-android-1".
    runtime_abi: Mapped[str] = mapped_column(String(64), default="ota-runtime-v1")
    # JSON written by `ota release android`: build arguments and hashes of everything a code patch
    # must NOT change (engine, native libraries, Java/Kotlin, manifest, assets). The CLI compares
    # a patch build against it and refuses changes that need a store release.
    fingerprint: Mapped[str] = mapped_column(Text, default="{}", server_default="{}")
    created_at: Mapped[datetime] = mapped_column(default=utc_now)

    application: Mapped[Application] = relationship()
    artifacts: Mapped[list["ReleaseArtifact"]] = relationship(back_populates="release")


class ReleaseArtifact(Base):
    """The base file a patch is diffed against (libapp.so on Android), one per arch."""

    __tablename__ = "release_artifacts"
    __table_args__ = (UniqueConstraint("release_id", "arch"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    release_id: Mapped[str] = mapped_column(ForeignKey("releases.id"), index=True)
    arch: Mapped[str] = mapped_column(String(32))
    sha256: Mapped[str] = mapped_column(String(64))
    size_bytes: Mapped[int] = mapped_column(Integer)
    storage_key: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(default=utc_now)

    release: Mapped[Release] = relationship(back_populates="artifacts")


class Patch(Base):
    __tablename__ = "patches"
    __table_args__ = (
        UniqueConstraint("release_id", "number"),
        CheckConstraint(
            "status IN ('draft', 'published', 'rolled_back', 'revoked')", name="ck_patch_status"
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    release_id: Mapped[str] = mapped_column(ForeignKey("releases.id"), index=True)
    number: Mapped[int] = mapped_column(Integer)
    artifact_format: Mapped[str] = mapped_column(String(32))
    # draft → published → rolled_back (can be published again) / revoked (final)
    status: Mapped[str] = mapped_column(String(16), default="draft")
    note: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(default=utc_now)

    release: Mapped[Release] = relationship()
    artifacts: Mapped[list["PatchArtifact"]] = relationship(back_populates="patch")
    deployments: Mapped[list["PatchDeployment"]] = relationship(back_populates="patch")


class PatchArtifact(Base):
    __tablename__ = "patch_artifacts"
    __table_args__ = (UniqueConstraint("patch_id", "arch"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    patch_id: Mapped[str] = mapped_column(ForeignKey("patches.id"), index=True)
    arch: Mapped[str] = mapped_column(String(32))
    base_artifact_sha256: Mapped[str] = mapped_column(String(64))
    payload_sha256: Mapped[str] = mapped_column(String(64))
    result_sha256: Mapped[str] = mapped_column(String(64))
    size_bytes: Mapped[int] = mapped_column(Integer)
    storage_key: Mapped[str] = mapped_column(String(200))
    signature: Mapped[str] = mapped_column(String(200))
    key_id: Mapped[str] = mapped_column(String(64))

    patch: Mapped[Patch] = relationship(back_populates="artifacts")


class PatchDeployment(Base):
    """A patch made available on one channel to rollout_bps / 10000 of devices."""

    __tablename__ = "patch_deployments"
    __table_args__ = (
        UniqueConstraint("patch_id", "channel_id"),
        CheckConstraint("rollout_bps BETWEEN 0 AND 10000", name="ck_rollout_bps"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    patch_id: Mapped[str] = mapped_column(ForeignKey("patches.id"), index=True)
    channel_id: Mapped[str] = mapped_column(ForeignKey("channels.id"), index=True)
    rollout_bps: Mapped[int] = mapped_column(Integer)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now, onupdate=utc_now)

    patch: Mapped[Patch] = relationship(back_populates="deployments")
    channel: Mapped[Channel] = relationship()


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (UniqueConstraint("application_id", "installation_id"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    application_id: Mapped[str] = mapped_column(ForeignKey("applications.id"), index=True)
    installation_id: Mapped[str] = mapped_column(String(128))
    platform: Mapped[str] = mapped_column(String(16))
    arch: Mapped[str] = mapped_column(String(32))
    release_version: Mapped[str] = mapped_column(String(64))
    channel: Mapped[str] = mapped_column(String(64))
    current_patch_number: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    last_seen: Mapped[datetime] = mapped_column(default=utc_now)


class PatchEventCount(Base):
    """Aggregated boot/install counters per patch (Phase 9, slimmed).

    At 1M installs this moves to Event Hubs + a worker that writes these same rows.
    """

    __tablename__ = "patch_event_counts"
    __table_args__ = (UniqueConstraint("patch_id", "event_type"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    patch_id: Mapped[str] = mapped_column(ForeignKey("patches.id"), index=True)
    event_type: Mapped[str] = mapped_column(String(64))
    count: Mapped[int] = mapped_column(Integer, default=0)
