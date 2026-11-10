"""The hot path: "is there a patch for this device?"

Order matters: compatibility first (release, platform, arch, format), rollout bucket last.
"""

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.auth import DeviceIdentity
from app.bucket import is_in_rollout, rollout_bucket
from app.config import Settings
from app.models import Channel, Device, Patch, Release
from app.schemas import UpdateCheckOut, UpdatePatch
from app.storage import Storage

LAST_SEEN_RESOLUTION = timedelta(hours=1)


def check_for_update(
    db: Session,
    settings: Settings,
    storage: Storage,
    identity: DeviceIdentity,
    *,
    platform: str,
    arch: str,
    release_version: str,
    channel: str,
    current_patch_number: int,
    supported_formats: set[str],
    failed_patch_ids: set[str] = frozenset(),
) -> UpdateCheckOut:
    app_id = identity.application_id
    no_update = UpdateCheckOut(
        update_available=False,
        application_id=app_id,
        release_id=None,
        next_check_after_seconds=settings.check_interval_seconds,
    )

    _touch_device(db, identity, release_version, channel, current_patch_number)

    release = db.scalar(
        select(Release).where(
            Release.application_id == app_id,
            Release.platform == platform,
            Release.version == release_version,
        )
    )
    if release is None:
        # Unknown store build (e.g. not registered yet). It simply runs its own code.
        return no_update
    no_update.release_id = release.id

    channel_row = db.scalar(
        select(Channel).where(Channel.application_id == app_id, Channel.name == channel)
    )

    patches = db.scalars(
        select(Patch)
        .where(Patch.release_id == release.id, Patch.status != "draft")
        .options(selectinload(Patch.artifacts), selectinload(Patch.deployments))
    ).all()

    rolled_back = sorted(p.number for p in patches if p.status == "rolled_back")
    revoked = sorted(p.number for p in patches if p.status == "revoked")

    best: tuple[Patch, object] | None = None
    if channel_row is not None:
        for patch in patches:
            if patch.status != "published" or patch.artifact_format not in supported_formats:
                continue
            if patch.id in failed_patch_ids:  # crashed on this device; offer the next best one
                continue
            deployment = next((d for d in patch.deployments if d.channel_id == channel_row.id), None)
            if deployment is None:
                continue
            artifact = next((a for a in patch.artifacts if a.arch == arch), None)
            if artifact is None:
                continue
            bucket = rollout_bucket(
                settings.rollout_hmac_secret, app_id, identity.installation_id, patch.id
            )
            if not is_in_rollout(bucket, deployment.rollout_bps):
                continue
            if best is None or patch.number > best[0].number:
                best = (patch, artifact)

    current_is_bad = current_patch_number in rolled_back or current_patch_number in revoked
    result = no_update.model_copy(
        update={"rolled_back_patch_numbers": rolled_back, "revoked_patch_numbers": revoked}
    )
    if current_is_bad:
        result.rollback_to_patch_number = best[0].number if best else 0

    if best is None:
        return result
    patch, artifact = best
    if patch.number == current_patch_number:
        return result
    # Never offer an older patch unless the current one is bad (anti-replay, ADR-0006).
    if patch.number < current_patch_number and not current_is_bad:
        return result

    result.update_available = True
    result.patch = UpdatePatch(
        id=patch.id,
        number=patch.number,
        artifact_format=patch.artifact_format,
        arch=artifact.arch,
        runtime_abi=release.runtime_abi,
        download_url=storage.url(artifact.storage_key),
        base_artifact_sha256=artifact.base_artifact_sha256,
        payload_sha256=artifact.payload_sha256,
        result_sha256=artifact.result_sha256,
        size_bytes=artifact.size_bytes,
        signature=artifact.signature,
        key_id=artifact.key_id,
    )
    return result


def _touch_device(
    db: Session,
    identity: DeviceIdentity,
    release_version: str,
    channel: str,
    current_patch_number: int,
) -> None:
    """Keep device info fresh without writing on every check (1M devices = lots of writes)."""
    device = db.get(Device, identity.device_id)
    if device is None:
        return
    now = datetime.now(timezone.utc)
    last_seen = device.last_seen
    if last_seen.tzinfo is None:  # SQLite drops the timezone.
        last_seen = last_seen.replace(tzinfo=timezone.utc)
    changed = (
        device.release_version != release_version
        or device.channel != channel
        or device.current_patch_number != current_patch_number
    )
    if changed or now - last_seen > LAST_SEEN_RESOLUTION:
        device.release_version = release_version
        device.channel = channel
        device.current_patch_number = current_patch_number
        device.last_seen = now
        db.commit()
