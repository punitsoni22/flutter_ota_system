# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Admin API for developer signing trust (dbc-v1). Everything here needs X-API-Key.

The server only STORES and CHECKS what the developer's offline root key signed: root public keys,
root-signed key certificates and root-signed revocation lists. It never creates or signs any of
them. {app} is the application id (UUID) or its slug.
"""

import json

from fastapi import APIRouter, Body, Depends, File, HTTPException, UploadFile, status
from fastapi.responses import JSONResponse
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app import dbc
from app.auth import require_admin
from app.db import get_db
from app.models import KeyCertificateRecord, Release, RevocationListRecord, TrustRoot
from app.schemas import (
    CertificateOut,
    RevocationListOut,
    TrustRootCreate,
    TrustRootOut,
    TrustStateOut,
)
from app.trust import (
    active_roots,
    app_by_ref,
    http_error,
    now_utc,
    read_limited,
    revocation_lists,
    revoked_state,
)

router = APIRouter(prefix="/v1/admin/apps/{app}/trust", tags=["trust"], dependencies=[Depends(require_admin)])


def _cert_out(row: KeyCertificateRecord) -> CertificateOut:
    return CertificateOut(
        serial=row.serial, key_id=row.key_id, roles=row.roles.split(","), environment=row.environment,
        not_before=row.not_before, not_after=row.not_after, root_key_id=row.root_key_id,
        certificate=json.loads(row.certificate),
    )


def _revocation_out(row: RevocationListRecord) -> RevocationListOut:
    body = dbc.parse_revocations(row.data, roots=None)
    return RevocationListOut(
        sequence=row.sequence, release_id=row.release_id, root_key_id=body.root_key_id,
        revoked_patch_ids=sorted(body.revoked.patch_ids), revoked_key_ids=sorted(body.revoked.key_ids),
        revoked_cert_serials=sorted(body.revoked.cert_serials), created_at=row.created_at,
    )


@router.get("", response_model=TrustStateOut)
def trust_state(app: str, db: Session = Depends(get_db)):
    application = app_by_ref(db, app)
    roots = db.scalars(
        select(TrustRoot).where(TrustRoot.application_id == application.id).order_by(TrustRoot.created_at)
    ).all()
    certs = db.scalars(
        select(KeyCertificateRecord)
        .where(KeyCertificateRecord.application_id == application.id)
        .order_by(KeyCertificateRecord.serial)
    ).all()
    return TrustStateOut(
        application_id=application.id,
        roots=[TrustRootOut.model_validate(r) for r in roots],
        certificates=[_cert_out(c) for c in certs],
        revocation_lists=[_revocation_out(r) for r in revocation_lists(db, application.id)],
    )


@router.post("/roots", response_model=TrustRootOut, status_code=201)
def register_root(app: str, body: TrustRootCreate, db: Session = Depends(get_db)):
    """Register a root PUBLIC key. Sending the same key again is accepted (200)."""
    application = app_by_ref(db, app)
    try:
        dbc.load_public_key(body.public_key)
    except dbc.Rejected as exc:
        raise http_error(exc) from exc
    existing = db.scalar(
        select(TrustRoot).where(TrustRoot.application_id == application.id, TrustRoot.key_id == body.key_id)
    )
    if existing is not None:
        if existing.public_key != body.public_key:
            raise HTTPException(status.HTTP_409_CONFLICT, f"Root key '{body.key_id}' exists with another public key")
        return JSONResponse(TrustRootOut.model_validate(existing).model_dump(mode="json"), status_code=200)
    root = TrustRoot(application_id=application.id, key_id=body.key_id, public_key=body.public_key)
    db.add(root)
    db.commit()
    return root


@router.post("/roots/{key_id}/revoke", response_model=TrustRootOut)
def revoke_root(app: str, key_id: str, db: Session = Depends(get_db)):
    """Stop trusting a root on the server: new certificates, lists and patches under it are refused.

    Devices keep trusting the root compiled into their build until a new store release.
    """
    application = app_by_ref(db, app)
    root = db.scalar(
        select(TrustRoot).where(TrustRoot.application_id == application.id, TrustRoot.key_id == key_id)
    )
    if root is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Root key '{key_id}' not found")
    if root.revoked_at is None:
        root.revoked_at = now_utc()
        db.commit()
    return root


@router.post("/certificates", response_model=CertificateOut, status_code=201)
def upload_certificate(app: str, certificate: dict = Body(...), db: Session = Depends(get_db)):
    """A root-signed key certificate {body, root_key_id, sig}, as the developer's tool wrote it."""
    application = app_by_ref(db, app)
    try:
        cert = dbc.verify_certificate(
            certificate,
            roots=active_roots(db, application.id),
            app_id=application.id,
            now=now_utc(),
            revoked=revoked_state(db, application.id),
        )
    except dbc.Rejected as exc:
        raise http_error(exc) from exc
    existing = db.scalar(
        select(KeyCertificateRecord).where(
            KeyCertificateRecord.application_id == application.id, KeyCertificateRecord.serial == cert.serial
        )
    )
    if existing is not None:
        if json.loads(existing.certificate) == certificate:
            return JSONResponse(_cert_out(existing).model_dump(mode="json"), status_code=200)
        raise http_error(dbc.Rejected("duplicate_serial", f"certificate serial {cert.serial} is already used"))
    row = KeyCertificateRecord(
        application_id=application.id, serial=cert.serial, key_id=cert.key_id, roles=",".join(cert.roles),
        environment=cert.environment, not_before=cert.not_before, not_after=cert.not_after,
        root_key_id=cert.root_key_id, certificate=dbc.canonical(certificate).decode("utf-8"),
    )
    db.add(row)
    db.commit()
    return _cert_out(row)


@router.post("/revocations", response_model=RevocationListOut, status_code=201)
def upload_revocations(app: str, file: UploadFile = File(...), db: Session = Depends(get_db)):
    """A root-signed revocation list (OTAPRT02 container with an empty module), stored unchanged.

    Its sequence must be higher than every earlier list of this app.
    """
    application = app_by_ref(db, app)
    data = read_limited(file, dbc.MAX_REVOCATION_BYTES)
    try:
        body = dbc.parse_revocations(data, roots=active_roots(db, application.id))
        release = db.get(Release, body.release_id)
        if release is None or release.application_id != application.id:
            raise dbc.Rejected("wrong_release", "release_id is not a release of this application")
        highest = db.scalar(
            select(func.max(RevocationListRecord.sequence)).where(
                RevocationListRecord.application_id == application.id
            )
        ) or 0
        if body.sequence <= highest:
            raise dbc.Rejected("stale_sequence", f"sequence {body.sequence} is not higher than {highest}")
    except dbc.Rejected as exc:
        raise http_error(exc) from exc
    row = RevocationListRecord(
        application_id=application.id, release_id=body.release_id, sequence=body.sequence, data=data
    )
    db.add(row)
    db.commit()
    return _revocation_out(row)
