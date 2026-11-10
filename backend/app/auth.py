# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

import hmac
import time
from dataclasses import dataclass

import jwt
from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings, get_settings

_bearer = HTTPBearer(auto_error=False)


def require_admin(
    x_api_key: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> None:
    """Shared admin API key for the CLI and CI. Per-person auth and roles are planned (roadmap Phase 8)."""
    if not x_api_key or not hmac.compare_digest(x_api_key, settings.admin_api_key):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or missing X-API-Key")


@dataclass(frozen=True)
class DeviceIdentity:
    device_id: str
    application_id: str
    installation_id: str


def issue_device_token(identity: DeviceIdentity, settings: Settings) -> tuple[str, int]:
    now = int(time.time())
    ttl = settings.device_token_ttl_seconds
    token = jwt.encode(
        {
            "sub": identity.device_id,
            "app": identity.application_id,
            "iid": identity.installation_id,
            "typ": "device",
            "iat": now,
            "exp": now + ttl,
        },
        settings.device_jwt_secret,
        algorithm="HS256",
    )
    return token, ttl


def require_device(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    settings: Settings = Depends(get_settings),
) -> DeviceIdentity:
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing device token")
    try:
        claims = jwt.decode(credentials.credentials, settings.device_jwt_secret, algorithms=["HS256"])
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid device token") from exc
    if claims.get("typ") != "device":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid device token")
    return DeviceIdentity(claims["sub"], claims["app"], claims["iid"])
