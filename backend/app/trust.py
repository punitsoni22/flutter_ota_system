# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Developer signing trust state (dbc-v1): roots, certificates, revocation lists, and the
dbc-v1 artifact upload. Verification itself is in app/dbc.py; this module reads and writes rows.
"""

import hashlib
import io
import json
from datetime import datetime, timezone

from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException, UploadFile, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import dbc
from app.models import (
    Application,
    KeyCertificateRecord,
    Patch,
    PatchArtifact,
    Release,
    ReleaseArtifact,
    RevocationListRecord,
    TrustRoot,
)
from app.storage import Storage

DEFAULT_ENVIRONMENT = "production"

# HTTP status per rejection code; everything else is 422.
_STATUS = {
    "too_large": status.HTTP_413_CONTENT_TOO_LARGE,
    "duplicate_patch_id": status.HTTP_409_CONFLICT,
    "replay": status.HTTP_409_CONFLICT,
    "cert_conflict": status.HTTP_409_CONFLICT,
    "duplicate_serial": status.HTTP_409_CONFLICT,
    "stale_sequence": status.HTTP_409_CONFLICT,
}


def http_error(exc: dbc.Rejected) -> HTTPException:
    return HTTPException(_STATUS.get(exc.code, status.HTTP_422_UNPROCESSABLE_CONTENT), f"{exc.code}: {exc.reason}")


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def aware(value: datetime | None) -> datetime | None:
    """SQLite drops the timezone; every stored time is UTC."""
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


def app_by_ref(db: Session, ref: str) -> Application:
    """Admin trust routes take the app id (UUID) or the slug."""
    app = db.get(Application, ref) or db.scalar(select(Application).where(Application.slug == ref))
    if app is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Application '{ref}' not found")
    return app


def active_roots(db: Session, application_id: str) -> dict[str, ec.EllipticCurvePublicKey]:
    rows = db.scalars(
        select(TrustRoot).where(TrustRoot.application_id == application_id, TrustRoot.revoked_at.is_(None))
    )
    return {r.key_id: dbc.load_public_key(r.public_key) for r in rows}


def revocation_lists(db: Session, application_id: str) -> list[RevocationListRecord]:
    return list(db.scalars(
        select(RevocationListRecord)
        .where(RevocationListRecord.application_id == application_id)
        .order_by(RevocationListRecord.sequence)
    ))


def revoked_state(db: Session, application_id: str) -> dbc.Revoked:
    """Union of every stored list of the app: a key revoked for one release is refused for all."""
    out = dbc.Revoked()
    for row in revocation_lists(db, application_id):
        r = dbc.parse_revocations(row.data, roots=None).revoked  # verified when it was stored
        out.patch_ids |= r.patch_ids
        out.key_ids |= r.key_ids
        out.cert_serials |= r.cert_serials
    return out


def latest_revocation_list(db: Session, application_id: str, release_id: str) -> RevocationListRecord | None:
    return db.scalar(
        select(RevocationListRecord)
        .where(RevocationListRecord.application_id == application_id, RevocationListRecord.release_id == release_id)
        .order_by(RevocationListRecord.sequence.desc())
        .limit(1)
    )


def read_limited(file: UploadFile, limit: int) -> bytes:
    """Read at most limit bytes; a bigger upload is refused without reading all of it."""
    data = file.file.read(limit + 1)
    if len(data) > limit:
        raise http_error(dbc.Rejected("too_large", f"file exceeds {limit} bytes"))
    return data


# ---- dbc-v1 artifact upload --------------------------------------------------------------


def _check_baseline_identity(release: Release, manifest: dict) -> None:
    tc = manifest["toolchain"]
    if release.toolchain_id and tc["id"] != release.toolchain_id:
        raise dbc.Rejected("wrong_toolchain", "built with another toolchain than the release")
    if release.dart_revision and tc["dart_revision"] != release.dart_revision:
        raise dbc.Rejected("wrong_toolchain", "built with another Dart revision than the release")
    if release.bytecode_format and tc["bytecode_format"] != release.bytecode_format:
        raise dbc.Rejected("wrong_toolchain", "built for another bytecode format than the release")
    if release.interface_sha256 and manifest["host_interface"]["sha256"] != release.interface_sha256:
        raise dbc.Rejected("wrong_interface", "built against another host interface than the release")


def _check_identity_and_order(db: Session, patch: Patch, arch: str, manifest: dict) -> None:
    patch_uuid, sequence = manifest["patch_id"], manifest["sequence"]
    reused = db.execute(
        select(PatchArtifact.patch_id, PatchArtifact.arch).where(PatchArtifact.manifest_patch_id == patch_uuid)
    ).all()
    if any(pid != patch.id or a == arch for pid, a in reused):
        raise dbc.Rejected("duplicate_patch_id", f"patch_id {patch_uuid} was already uploaded")

    # Sequences grow with the patch number, so "newest patch" means the same on server and device.
    rows = db.execute(
        select(Patch.id, Patch.number, PatchArtifact.sequence)
        .join(PatchArtifact, PatchArtifact.patch_id == Patch.id)
        .where(Patch.release_id == patch.release_id, PatchArtifact.sequence.is_not(None))
    ).all()
    for pid, number, seq in rows:
        if pid == patch.id and seq != sequence:
            raise dbc.Rejected("replay", f"all architectures of one patch must use sequence {seq}")
        if pid != patch.id and number < patch.number and seq >= sequence:
            raise dbc.Rejected("replay", f"sequence {sequence} is not newer than {seq} (patch #{number})")
        if pid != patch.id and number > patch.number and seq <= sequence:
            raise dbc.Rejected("replay", f"sequence {sequence} is not older than {seq} (newer patch #{number})")


def store_dbc_artifact(db: Session, storage: Storage, patch: Patch, arch: str, file: UploadFile) -> None:
    """Verify a developer-signed container and store it unchanged. Never signs anything."""
    release = db.get(Release, patch.release_id)
    assert release is not None
    base = db.scalar(
        select(ReleaseArtifact).where(ReleaseArtifact.release_id == release.id, ReleaseArtifact.arch == arch)
    )
    if base is None:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            f"Upload the release's base {arch} artifact (libapp.so) before a dbc-v1 patch",
        )
    data = read_limited(file, dbc.MAX_CONTAINER_BYTES)
    try:
        verified = dbc.verify_patch_container(
            data,
            app_id=release.application_id,
            release_id=release.id,
            baseline_sha256=base.sha256,
            roots=active_roots(db, release.application_id),
            environment=release.trust_environment or DEFAULT_ENVIRONMENT,
            revoked=revoked_state(db, release.application_id),
            now=now_utc(),
        )
        _check_baseline_identity(release, verified.manifest)
        cert = verified.certificate
        known = db.scalar(
            select(KeyCertificateRecord).where(
                KeyCertificateRecord.application_id == release.application_id,
                KeyCertificateRecord.serial == cert.serial,
            )
        )
        if known is not None and json.loads(known.certificate)["body"] != cert.body:
            raise dbc.Rejected("cert_conflict", f"another certificate with serial {cert.serial} is registered")
        _check_identity_and_order(db, patch, arch, verified.manifest)
    except dbc.Rejected as exc:
        raise http_error(exc) from exc

    stored = storage.put(io.BytesIO(data), "patches")
    db.add(
        PatchArtifact(
            patch_id=patch.id,
            arch=arch,
            base_artifact_sha256=base.sha256,
            payload_sha256=stored.sha256,
            result_sha256=verified.manifest["module"]["sha256"],
            size_bytes=stored.size_bytes,
            storage_key=stored.storage_key,
            signature=None,
            key_id=None,
            manifest=verified.manifest_bytes.decode("utf-8"),
            manifest_sha256=hashlib.sha256(verified.manifest_bytes).hexdigest(),
            manifest_patch_id=verified.manifest["patch_id"],
            sequence=verified.manifest["sequence"],
            signer_key_id=cert.key_id,
            cert_serial=cert.serial,
            expires_at=verified.expires_at,
        )
    )
    db.commit()
    db.expire_all()
