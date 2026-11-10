# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Device API: register, check for updates, report events. Called by the Flutter ota_client."""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth import DeviceIdentity, issue_device_token, require_device
from app.config import Settings, get_settings
from app.db import get_db
from app.deps import get_storage
from app.models import Application, Device, Patch, PatchEventCount, Release
from app.schemas import (
    ARCH,
    DeviceRegister,
    DeviceRegisterOut,
    EventBatch,
    Platform,
    UpdateCheckOut,
)
from app.storage import Storage
from app.updates import check_for_update

router = APIRouter(prefix="/v1", tags=["devices"])


@router.post("/devices/register", response_model=DeviceRegisterOut)
def register_device(
    body: DeviceRegister,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
):
    """Idempotent: the same installation_id always maps to the same device."""
    app = db.scalar(select(Application).where(Application.slug == body.app))
    if app is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Unknown application")

    def find() -> Device | None:
        return db.scalar(
            select(Device).where(
                Device.application_id == app.id, Device.installation_id == body.installation_id
            )
        )

    device = find()
    if device is None:
        device = Device(
            application_id=app.id,
            installation_id=body.installation_id,
            platform=body.platform,
            arch=body.arch,
            release_version=body.release_version,
            channel=body.channel,
        )
        db.add(device)
        try:
            db.commit()
        except IntegrityError:  # Registered concurrently; use the existing row.
            db.rollback()
            device = find()
            assert device is not None
    else:
        device.platform = body.platform
        device.arch = body.arch
        device.release_version = body.release_version
        device.channel = body.channel
        device.last_seen = datetime.now(timezone.utc)
        db.commit()

    token, ttl = issue_device_token(
        DeviceIdentity(device.id, app.id, device.installation_id), settings
    )
    return DeviceRegisterOut(device_id=device.id, access_token=token, expires_in=ttl)


@router.get("/updates/check", response_model=UpdateCheckOut)
def update_check(
    platform: Platform,
    arch: str = Query(pattern=ARCH),
    release_version: str = Query(min_length=1, max_length=64),
    channel: str = Query(default="production", max_length=64),
    current_patch_number: int = Query(default=0, ge=0),
    supported_formats: str = Query(default="mock-v1", max_length=200),
    # Patches that crashed on this device (up to 20). They are skipped when picking a patch.
    failed_patch_ids: str = Query(default="", max_length=1000),
    identity: DeviceIdentity = Depends(require_device),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
):
    return check_for_update(
        db,
        settings,
        storage,
        identity,
        platform=platform,
        arch=arch,
        release_version=release_version,
        channel=channel,
        current_patch_number=current_patch_number,
        supported_formats={f.strip() for f in supported_formats.split(",") if f.strip()},
        failed_patch_ids={p.strip() for p in failed_patch_ids.split(",") if p.strip()},
    )


@router.post("/events/batch", status_code=202)
def events_batch(
    body: EventBatch,
    identity: DeviceIdentity = Depends(require_device),
    db: Session = Depends(get_db),
):
    """Counts boot/install outcomes per patch. Unknown or foreign patch ids are ignored."""
    counts: dict[tuple[str, str], int] = {}
    for event in body.events:
        key = (event.patch_id, event.type)
        counts[key] = counts.get(key, 0) + 1

    patch_ids = {pid for pid, _ in counts}
    valid = set(
        db.scalars(
            select(Patch.id)
            .join(Release, Release.id == Patch.release_id)
            .where(Patch.id.in_(patch_ids), Release.application_id == identity.application_id)
        )
    )
    for (patch_id, event_type), n in counts.items():
        if patch_id not in valid:
            continue
        row = db.scalar(
            select(PatchEventCount)
            .where(PatchEventCount.patch_id == patch_id, PatchEventCount.event_type == event_type)
            .with_for_update()
        )
        if row is None:
            db.add(PatchEventCount(patch_id=patch_id, event_type=event_type, count=n))
        else:
            row.count += n
    try:
        db.commit()
    except IntegrityError:
        db.rollback()  # A concurrent first insert won; dropping one batch of counters is acceptable.
    return {"accepted": sum(counts.values())}
