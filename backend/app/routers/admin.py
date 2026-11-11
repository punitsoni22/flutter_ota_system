# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Admin API for the `ota` CLI and CI. Everything here needs X-API-Key."""

import json
import logging
import re

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import StreamingResponse
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from app.auth import require_admin
from app.config import Settings, get_settings
from app.canonical import SignedFields
from app.db import get_db
from app.deps import get_signer, get_storage
from app.models import (
    AOT_FORMATS,
    DEFAULT_CHANNELS,
    Application,
    Channel,
    Device,
    Patch,
    PatchArtifact,
    PatchDeployment,
    PatchEventCount,
    PolicyApprovalRecord,
    Release,
    ReleaseArtifact,
)
from app.schemas import (
    ARCH,
    AppCreate,
    AppOut,
    DeploymentOut,
    PatchArtifactOut,
    PatchCreate,
    PatchOut,
    PolicyApproval,
    PolicyApprovalOut,
    ReleaseArtifactOut,
    ReleaseCreate,
    ReleaseOut,
    RolloutRequest,
)
from app.signing import Signer, public_key_info
from app.storage import Storage

router = APIRouter(prefix="/v1/admin", tags=["admin"], dependencies=[Depends(require_admin)])

SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
NO_BASE = "0" * 64


# ---- helpers -----------------------------------------------------------------------------


def _app_by_slug(db: Session, slug: str) -> Application:
    app = db.scalar(select(Application).where(Application.slug == slug))
    if app is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Application '{slug}' not found")
    return app


def _release(db: Session, release_id: str) -> Release:
    release = db.get(Release, release_id, options=[selectinload(Release.artifacts)])
    if release is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Release not found")
    return release


def _patch(db: Session, patch_id: str) -> Patch:
    patch = db.get(
        Patch,
        patch_id,
        options=[
            selectinload(Patch.artifacts),
            selectinload(Patch.deployments).selectinload(PatchDeployment.channel),
            selectinload(Patch.release).selectinload(Release.application),
        ],
    )
    if patch is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Patch not found")
    return patch


def _channel(db: Session, application_id: str, name: str) -> Channel:
    channel = db.scalar(
        select(Channel).where(Channel.application_id == application_id, Channel.name == name)
    )
    if channel is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Channel '{name}' not found")
    return channel


def _release_out(release: Release, storage: Storage) -> ReleaseOut:
    out = ReleaseOut.model_validate(release)
    out.artifacts = [
        # Admin-only download: the base is the app's whole compiled code, so it is never on the CDN.
        ReleaseArtifactOut(
            arch=a.arch,
            sha256=a.sha256,
            size_bytes=a.size_bytes,
            url=f"/v1/admin/releases/{release.id}/artifacts/{a.arch}",
        )
        for a in release.artifacts
    ]
    return out


def _patch_out(db: Session, patch: Patch, storage: Storage) -> PatchOut:
    out = PatchOut(
        id=patch.id,
        release_id=patch.release_id,
        release_version=patch.release.version,
        platform=patch.release.platform,
        number=patch.number,
        artifact_format=patch.artifact_format,
        status=patch.status,
        note=patch.note,
        created_at=patch.created_at,
    )
    out.artifacts = [
        PatchArtifactOut.model_validate(a).model_copy(update={"url": storage.url(a.storage_key)})
        for a in patch.artifacts
    ]
    out.deployments = [
        DeploymentOut(channel=d.channel.name, rollout_percent=d.rollout_bps / 100)
        for d in patch.deployments
    ]
    counts = db.scalars(select(PatchEventCount).where(PatchEventCount.patch_id == patch.id))
    out.event_counts = {c.event_type: c.count for c in counts}
    return out


# ---- applications ------------------------------------------------------------------------


@router.post("/apps", response_model=AppOut, status_code=201)
def create_app(body: AppCreate, db: Session = Depends(get_db)):
    if db.scalar(select(Application).where(Application.slug == body.slug)):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Application '{body.slug}' already exists")
    app = Application(slug=body.slug, name=body.name, distribution=body.distribution)
    db.add(app)
    db.flush()
    for name in DEFAULT_CHANNELS:
        db.add(Channel(application_id=app.id, name=name))
    db.commit()
    return app


@router.get("/apps", response_model=list[AppOut])
def list_apps(db: Session = Depends(get_db)):
    return db.scalars(select(Application).order_by(Application.created_at)).all()


@router.post("/apps/{slug}/policy-approval", response_model=AppOut)
def set_policy_approval(slug: str, body: PolicyApproval, db: Session = Depends(get_db)):
    """ADR-0011: record that AOT code patches are approved for this public store app.

    Every approval or withdrawal is kept with its reason and time (KI-2).
    """
    app = _app_by_slug(db, slug)
    app.aot_policy_approved = body.approved
    db.add(PolicyApprovalRecord(application_id=app.id, approved=body.approved, reason=body.reason.strip()))
    db.commit()
    db.refresh(app)
    return app


@router.get("/apps/{slug}/policy-approvals", response_model=list[PolicyApprovalOut])
def list_policy_approvals(slug: str, db: Session = Depends(get_db)):
    """History of policy approvals and withdrawals for this app, newest first (KI-2)."""
    return _app_by_slug(db, slug).policy_approvals


@router.get("/apps/{slug}/channels", response_model=list[str])
def list_channels(slug: str, db: Session = Depends(get_db)):
    app = _app_by_slug(db, slug)
    return [c.name for c in db.scalars(select(Channel).where(Channel.application_id == app.id))]


@router.post("/apps/{slug}/channels", response_model=list[str], status_code=201)
def create_channel(slug: str, name: str = Form(pattern=r"^[a-z0-9-]{1,64}$"), db: Session = Depends(get_db)):
    app = _app_by_slug(db, slug)
    db.add(Channel(application_id=app.id, name=name))
    try:
        db.commit()
    except IntegrityError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, "Channel already exists") from exc
    return list_channels(slug, db)


@router.get("/apps/{slug}/devices/summary")
def device_summary(slug: str, db: Session = Depends(get_db)):
    """How many devices run each release / channel / patch (from their last check)."""
    app = _app_by_slug(db, slug)
    rows = db.execute(
        select(Device.platform, Device.release_version, Device.channel, Device.current_patch_number, func.count())
        .where(Device.application_id == app.id)
        .group_by(Device.platform, Device.release_version, Device.channel, Device.current_patch_number)
    ).all()
    return [
        {"platform": p, "release_version": v, "channel": c, "patch_number": n, "devices": count}
        for p, v, c, n, count in rows
    ]


# ---- releases ----------------------------------------------------------------------------


@router.post("/apps/{slug}/releases", response_model=ReleaseOut, status_code=201)
def create_release(
    slug: str,
    body: ReleaseCreate,
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
):
    app = _app_by_slug(db, slug)
    fields = body.model_dump()
    replace = fields.pop("replace")
    fields["fingerprint"] = json.dumps(fields["fingerprint"], sort_keys=True)
    exists = db.scalar(
        select(func.count()).select_from(Release).where(
            Release.application_id == app.id,
            Release.platform == body.platform,
            Release.version == body.version,
        )
    )
    if not exists and not replace:
        # KI-1: installs remember the deleted release's id. A new id makes them drop its patches.
        in_use = db.scalar(
            select(func.count()).select_from(Device).where(
                Device.application_id == app.id,
                Device.platform == body.platform,
                Device.release_version == body.version,
            )
        )
        if in_use:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"{in_use} device(s) still report {body.platform} {body.version} from a deleted "
                "release. Registering it again makes them drop that release's patches. Give the "
                "new build a new build number, or pass replace=true (CLI: --replace)",
            )
    release = Release(application_id=app.id, **fields)
    db.add(release)
    try:
        db.commit()
    except IntegrityError as exc:
        raise HTTPException(
            status.HTTP_409_CONFLICT, f"Release {body.platform} {body.version} already exists"
        ) from exc
    return _release_out(_release(db, release.id), storage)


@router.get("/apps/{slug}/releases", response_model=list[ReleaseOut])
def list_releases(
    slug: str, db: Session = Depends(get_db), storage: Storage = Depends(get_storage)
):
    app = _app_by_slug(db, slug)
    releases = db.scalars(
        select(Release)
        .where(Release.application_id == app.id)
        .options(selectinload(Release.artifacts))
        .order_by(Release.created_at)
    ).all()
    return [_release_out(r, storage) for r in releases]


@router.post("/releases/{release_id}/artifacts", response_model=ReleaseOut, status_code=201)
def upload_release_artifact(
    release_id: str,
    arch: str = Form(pattern=ARCH),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
):
    """The base file patches are diffed against (libapp.so per ABI on Android). Immutable."""
    release = _release(db, release_id)
    if any(a.arch == arch for a in release.artifacts):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Release already has a {arch} artifact")
    stored = storage.put(file.file, "releases")
    db.add(
        ReleaseArtifact(
            release_id=release.id,
            arch=arch,
            sha256=stored.sha256,
            size_bytes=stored.size_bytes,
            storage_key=stored.storage_key,
        )
    )
    db.commit()
    db.expire_all()
    return _release_out(_release(db, release.id), storage)


@router.get("/releases/{release_id}/artifacts/{arch}")
def download_release_artifact(
    release_id: str,
    arch: str,
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
):
    """The store build's libapp.so for one ABI, for `ota patch android` to diff against."""
    artifact = next((a for a in _release(db, release_id).artifacts if a.arch == arch), None)
    if artifact is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Release has no {arch} artifact")
    return StreamingResponse(storage.read(artifact.storage_key), media_type="application/octet-stream")


@router.delete("/releases/{release_id}", status_code=204)
def delete_release(release_id: str, db: Session = Depends(get_db)):
    """Remove a test release and its patches. Refused while a patch is live on devices."""
    release = _release(db, release_id)
    patches = db.scalars(select(Patch).where(Patch.release_id == release.id)).all()
    if any(p.status == "published" for p in patches):
        raise HTTPException(status.HTTP_409_CONFLICT, "Roll back or revoke its published patches first")
    patch_ids = [p.id for p in patches]
    for model in (PatchDeployment, PatchArtifact, PatchEventCount):
        db.execute(delete(model).where(model.patch_id.in_(patch_ids)))
    db.execute(delete(Patch).where(Patch.release_id == release.id))
    db.execute(delete(ReleaseArtifact).where(ReleaseArtifact.release_id == release.id))
    db.delete(release)
    db.commit()
    # Stored files stay: they are content-addressed and may be shared with other releases.


# ---- patches -----------------------------------------------------------------------------


@router.post("/releases/{release_id}/patches", response_model=PatchOut, status_code=201)
def create_patch(
    release_id: str,
    body: PatchCreate,
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
):
    release = _release(db, release_id)
    if body.artifact_format == "aot-bidiff-android-v1" and release.platform != "android":
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "AOT patches are Android-only")
    for _ in range(3):  # Retry if two creators race for the same number.
        number = (
            db.scalar(select(func.max(Patch.number)).where(Patch.release_id == release.id)) or 0
        ) + 1
        patch = Patch(
            release_id=release.id, number=number, artifact_format=body.artifact_format, note=body.note
        )
        db.add(patch)
        try:
            db.commit()
            return _patch_out(db, _patch(db, patch.id), storage)
        except IntegrityError:
            db.rollback()
    raise HTTPException(status.HTTP_409_CONFLICT, "Could not allocate a patch number, retry")


@router.get("/releases/{release_id}/patches", response_model=list[PatchOut])
def list_patches(
    release_id: str, db: Session = Depends(get_db), storage: Storage = Depends(get_storage)
):
    _release(db, release_id)
    ids = db.scalars(
        select(Patch.id).where(Patch.release_id == release_id).order_by(Patch.number)
    ).all()
    return [_patch_out(db, _patch(db, pid), storage) for pid in ids]


@router.get("/patches/{patch_id}", response_model=PatchOut)
def get_patch(patch_id: str, db: Session = Depends(get_db), storage: Storage = Depends(get_storage)):
    return _patch_out(db, _patch(db, patch_id), storage)


@router.post("/patches/{patch_id}/artifacts", response_model=PatchOut, status_code=201)
def upload_patch_artifact(
    patch_id: str,
    arch: str = Form(pattern=ARCH),
    result_sha256: str | None = Form(default=None),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
    signer: Signer = Depends(get_signer),
):
    """Store the patch file, then sign the canonical message (ADR-0002) for this arch."""
    patch = _patch(db, patch_id)
    if patch.status != "draft":
        raise HTTPException(status.HTTP_409_CONFLICT, "Artifacts can only be added to a draft patch")
    if any(a.arch == arch for a in patch.artifacts):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Patch already has a {arch} artifact")

    release = patch.release
    base = next((a for a in _release(db, release.id).artifacts if a.arch == arch), None)
    if patch.artifact_format in AOT_FORMATS:
        if base is None:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_CONTENT,
                f"Upload the release's base {arch} artifact before an AOT patch",
            )
        if not result_sha256 or not SHA256_HEX.match(result_sha256):
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_CONTENT,
                "AOT patches need result_sha256 (hash of the rebuilt libapp.so, lowercase hex)",
            )

    stored = storage.put(file.file, "patches")
    if result_sha256 is None:
        result_sha256 = stored.sha256  # mock-v1: the payload is the result.
    elif not SHA256_HEX.match(result_sha256):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "result_sha256 must be lowercase hex")
    base_sha = base.sha256 if base else NO_BASE

    fields = SignedFields(
        application_id=release.application_id,
        release_id=release.id,
        patch_number=patch.number,
        platform=release.platform,
        arch=arch,
        runtime_abi=release.runtime_abi,
        artifact_format=patch.artifact_format,
        base_artifact_sha256=base_sha,
        payload_sha256=stored.sha256,
        result_sha256=result_sha256,
        size_bytes=stored.size_bytes,
    )
    db.add(
        PatchArtifact(
            patch_id=patch.id,
            arch=arch,
            base_artifact_sha256=base_sha,
            payload_sha256=stored.sha256,
            result_sha256=result_sha256,
            size_bytes=stored.size_bytes,
            storage_key=stored.storage_key,
            signature=signer.sign(fields.message()),
            key_id=signer.key_id,
        )
    )
    db.commit()
    db.expire_all()
    return _patch_out(db, _patch(db, patch.id), storage)


log = logging.getLogger("flutter_ota_system.admin")


def _check_promotion(db: Session, patch: Patch, body: RolloutRequest, settings: Settings) -> None:
    """KI-4: a protected channel (production) only gets a patch that was tested elsewhere.

    Raising the percentage on a protected channel needs (1) a deployment above 0% on another,
    unprotected channel (e.g. staging) or on this channel already, and (2) no reported boot
    failures. Lowering a percentage, rolling back and revoking are never blocked.
    """
    protected = settings.protected_channel_names()
    if body.channel not in protected:
        return
    current = next((d for d in patch.deployments if d.channel.name == body.channel), None)
    current_bps = current.rollout_bps if current and patch.status == "published" else 0
    if round(body.rollout_percent * 100) <= current_bps:
        return
    problems = []
    tested = any(d.rollout_bps > 0 and d.channel.name not in protected for d in patch.deployments)
    if not tested and current_bps == 0:
        problems.append(f"it has not been on a test channel (e.g. staging) before '{body.channel}'")
    failed = db.scalar(
        select(PatchEventCount.count).where(
            PatchEventCount.patch_id == patch.id, PatchEventCount.event_type == "patch_boot_failed"
        )
    ) or 0
    if failed:
        problems.append(f"{failed} device(s) reported a boot failure")
    if not problems:
        return
    if not body.force:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"promotion_checks_failed: patch #{patch.number}: " + "; ".join(problems)
            + ". Fix it, or send force=true with a reason (CLI: --force --reason)",
        )
    if not body.reason or len(body.reason.strip()) < 3:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "force=true needs a reason (3+ characters)")
    log.warning(
        "Promotion checks overridden: patch %s (#%s) -> %s %.2f%%: %s. Reason: %s",
        patch.id, patch.number, body.channel, body.rollout_percent, "; ".join(problems), body.reason.strip(),
    )


def _set_rollout(db: Session, patch: Patch, body: RolloutRequest) -> None:
    channel = _channel(db, patch.release.application_id, body.channel)
    bps = round(body.rollout_percent * 100)
    deployment = next((d for d in patch.deployments if d.channel_id == channel.id), None)
    if deployment is None:
        db.add(PatchDeployment(patch_id=patch.id, channel_id=channel.id, rollout_bps=bps))
    else:
        deployment.rollout_bps = bps


@router.post("/patches/{patch_id}/publish", response_model=PatchOut)
def publish_patch(
    patch_id: str,
    body: RolloutRequest,
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
    settings: Settings = Depends(get_settings),
):
    patch = _patch(db, patch_id)
    if patch.status not in ("draft", "rolled_back"):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Cannot publish a {patch.status} patch")
    if not patch.artifacts:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Patch has no artifacts")
    app = patch.release.application
    if (
        patch.artifact_format in AOT_FORMATS
        and app.distribution == "public_store"
        and not app.aot_policy_approved
    ):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "policy_review_required: AOT code patches for public store apps need "
            "`ota app approve-policy` first (ADR-0011)",
        )
    _check_promotion(db, patch, body, settings)
    _set_rollout(db, patch, body)
    patch.status = "published"
    db.commit()
    db.expire_all()
    return _patch_out(db, _patch(db, patch.id), storage)


@router.post("/patches/{patch_id}/rollout", response_model=PatchOut)
def change_rollout(
    patch_id: str,
    body: RolloutRequest,
    db: Session = Depends(get_db),
    storage: Storage = Depends(get_storage),
    settings: Settings = Depends(get_settings),
):
    patch = _patch(db, patch_id)
    if patch.status != "published":
        raise HTTPException(status.HTTP_409_CONFLICT, "Only published patches have a rollout")
    _check_promotion(db, patch, body, settings)
    _set_rollout(db, patch, body)
    db.commit()
    db.expire_all()
    return _patch_out(db, _patch(db, patch.id), storage)


@router.post("/patches/{patch_id}/rollback", response_model=PatchOut)
def rollback_patch(
    patch_id: str, db: Session = Depends(get_db), storage: Storage = Depends(get_storage)
):
    """Devices on this patch go back to the newest other eligible patch (or the store build).

    It can be published again later. Use revoke if it must never run again.
    """
    patch = _patch(db, patch_id)
    if patch.status != "published":
        raise HTTPException(status.HTTP_409_CONFLICT, f"Cannot roll back a {patch.status} patch")
    patch.status = "rolled_back"
    db.commit()
    return _patch_out(db, _patch(db, patch.id), storage)


@router.post("/patches/{patch_id}/revoke", response_model=PatchOut)
def revoke_patch(
    patch_id: str, db: Session = Depends(get_db), storage: Storage = Depends(get_storage)
):
    """Permanent: the patch must never run again on any device."""
    patch = _patch(db, patch_id)
    if patch.status == "revoked":
        raise HTTPException(status.HTTP_409_CONFLICT, "Patch is already revoked")
    patch.status = "revoked"
    db.commit()
    return _patch_out(db, _patch(db, patch.id), storage)


# ---- keys --------------------------------------------------------------------------------


@router.get("/signing-key")
def signing_key(signer: Signer = Depends(get_signer)):
    """The public key to embed in the app (never the private key)."""
    return public_key_info(signer)
