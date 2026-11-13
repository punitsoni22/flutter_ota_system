# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Developer-signed bytecode patches ("dbc-v1"): parsing and verification only.

The server NEVER signs these. It checks them before devices see them, with the same rules as the
device verifier (packages/patch_security in the Phase 3 prototype), so a bad patch is refused at
upload time instead of on thousands of phones.

Container "OTAPRT02":
    magic | u32 BE manifest length | manifest (canonical JSON)
          | u32 BE signature length | signature block (canonical JSON) | module bytes

Trust chain: app ROOT key (registered on the server, offline private key)
    -> signs a KEY CERTIFICATE for a signer/approver key
    -> the certified key signs the manifest.
A root key also signs revocation lists (same container, empty module).
"""

import base64
import hashlib
import json
import re
import struct
from dataclasses import dataclass, field
from datetime import datetime, timezone

from cryptography.hazmat.primitives.asymmetric import ec

from app.signing import verify as es256_verify

MAGIC = b"OTAPRT02"
MANIFEST_DOMAIN = b"flutter-ota-system/patch-manifest/v2\n"
REVOCATION_DOMAIN = b"flutter-ota-system/revocations/v1\n"
KEY_CERT_DOMAIN = b"flutter-ota-system/key-certificate/v1\n"
APPROVAL_DOMAIN = b"flutter-ota-system/patch-approval/v1\n"

# Same limits as the device (container.dart).
MAX_CONTAINER_BYTES = 8 * 1024 * 1024
MAX_MANIFEST_BYTES = 64 * 1024
MAX_SIGNATURE_BYTES = 8 * 1024
# A revocation list is small; refuse anything bigger.
MAX_REVOCATION_BYTES = 256 * 1024

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
SHA = re.compile(r"[0-9a-f]{64}")
PKG = re.compile(r"[a-z][a-z0-9_]{0,63}")
KEY_ID = re.compile(r"[A-Za-z0-9._-]{1,64}")
VERSION = re.compile(r"[0-9A-Za-z.+-]{1,64}")
ISO_UTC = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")

TOOLCHAIN_FIELDS = (
    "flutter", "dart", "engine", "dart_revision", "engine_patch_sha256", "compiler_sha256",
    "generator_sha256", "bytecode_format", "build_config_sha256",
)
ROLES = {"signer", "approver"}


class Rejected(Exception):
    """A stable machine-readable code (same names as the device verifier) and a reason."""

    def __init__(self, code: str, reason: str):
        super().__init__(f"{code}: {reason}")
        self.code = code
        self.reason = reason


# ---- canonical JSON ----------------------------------------------------------------------


# Signed documents are shallow (a few levels); this bound keeps hostile input from exhausting the
# stack. The Dart SDK uses the same limit.
MAX_JSON_DEPTH = 32


def canonical(value) -> bytes:
    """UTF-8, sorted keys, no whitespace, integers only. Same bytes as canonicalJson in Dart."""

    def check(v, depth):
        if isinstance(v, float):
            raise ValueError("floats are not allowed in canonical JSON")
        if isinstance(v, (dict, list)) and depth >= MAX_JSON_DEPTH:
            raise ValueError(f"JSON is nested more than {MAX_JSON_DEPTH} levels deep")
        if isinstance(v, dict):
            for k, x in v.items():
                if not isinstance(k, str) or not k.isascii():
                    raise ValueError("keys must be ASCII strings")
                check(x, depth + 1)
        elif isinstance(v, list):
            for x in v:
                check(x, depth + 1)
        elif not (v is None or isinstance(v, (bool, int, str))):
            raise ValueError(f"{type(v).__name__} is not allowed in canonical JSON")

    check(value, 0)
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def _no_float(text: str):
    raise ValueError("floats are not allowed")


def _no_constant(text: str):
    raise ValueError(f"{text} is not allowed")


def parse_canonical(data: bytes, code: str) -> dict:
    """Parse bytes that must be exactly the canonical encoding of a JSON object."""
    try:
        value = json.loads(data.decode("utf-8"), parse_float=_no_float, parse_constant=_no_constant)
        if not isinstance(value, dict):
            raise ValueError("not a JSON object")
        if canonical(value) != data:
            raise ValueError("not in canonical form")
    except RecursionError as exc:  # json.loads itself on extremely deep input
        raise Rejected(code, "JSON is nested too deeply") from exc
    except (UnicodeDecodeError, ValueError) as exc:
        raise Rejected(code, str(exc)) from exc
    return value


# ---- container ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Parts:
    manifest: bytes
    signature: bytes
    module: bytes


def split_container(data: bytes, max_bytes: int = MAX_CONTAINER_BYTES) -> Parts:
    if len(data) > max_bytes:
        raise Rejected("too_large", f"file exceeds {max_bytes} bytes")
    if len(data) < 16:
        raise Rejected("truncated", "file is shorter than the container header")
    if data[:8] != MAGIC:
        raise Rejected("bad_magic", "not an OTAPRT02 container")
    m_len = struct.unpack(">I", data[8:12])[0]
    if m_len == 0 or m_len > MAX_MANIFEST_BYTES:
        raise Rejected("bad_manifest_length", f"manifest length {m_len} out of range")
    if 12 + m_len + 4 > len(data):
        raise Rejected("truncated", "manifest extends past the end of the file")
    s_len = struct.unpack(">I", data[12 + m_len:16 + m_len])[0]
    if s_len == 0 or s_len > MAX_SIGNATURE_BYTES:
        raise Rejected("bad_signature_length", f"signature length {s_len} out of range")
    start = 16 + m_len + s_len
    if start > len(data):
        raise Rejected("truncated", "signature extends past the end of the file")
    return Parts(data[12:12 + m_len], data[16 + m_len:start], data[start:])


# ---- keys and signatures -----------------------------------------------------------------


def load_public_key(b64: str) -> ec.EllipticCurvePublicKey:
    """A base64 uncompressed P-256 point (65 bytes, 0x04 || X || Y), as apps embed it."""
    try:
        raw = base64.b64decode(b64, validate=True)
        if len(raw) != 65 or raw[0] != 4:
            raise ValueError("not an uncompressed point")
        return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)
    except (ValueError, TypeError) as exc:
        raise Rejected("bad_public_key", "public key must be a base64 uncompressed P-256 point") from exc


def verify_sig(public_key: ec.EllipticCurvePublicKey, domain: bytes, body: bytes, sig) -> bool:
    if not isinstance(sig, str):
        return False
    try:
        return es256_verify(public_key, domain + body, sig)
    except (ValueError, TypeError):
        return False


def parse_time(value, what: str, code: str = "bad_certificate") -> datetime:
    if not isinstance(value, str) or not ISO_UTC.fullmatch(value):
        raise Rejected(code, f"{what} is not a UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise Rejected(code, f"{what} is not a valid date") from exc


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


# ---- revocation state --------------------------------------------------------------------


@dataclass
class Revoked:
    patch_ids: set[str] = field(default_factory=set)
    key_ids: set[str] = field(default_factory=set)
    cert_serials: set[int] = field(default_factory=set)


# ---- key certificates --------------------------------------------------------------------

CERT_FIELDS = {"type", "app_id", "environment", "key_id", "public_key", "roles", "serial", "not_before", "not_after"}


@dataclass(frozen=True)
class Certificate:
    body: dict
    root_key_id: str
    key_id: str
    public_key: ec.EllipticCurvePublicKey
    public_key_b64: str
    serial: int
    roles: list[str]
    environment: str
    not_before: datetime
    not_after: datetime


def verify_certificate(
    cert,
    *,
    roots: dict[str, ec.EllipticCurvePublicKey],
    app_id: str,
    now: datetime,
    revoked: Revoked,
    role: str | None = None,
    environment: str | None = None,
) -> Certificate:
    """{body, root_key_id, sig}: issued by a registered root of this app, for this app.

    role / environment are checked only when given (an upload of a certificate stores both).
    """
    if not isinstance(cert, dict) or set(cert) - {"body", "root_key_id", "sig"}:
        raise Rejected("bad_certificate", "certificate has an invalid shape")
    body, root_id, sig = cert.get("body"), cert.get("root_key_id"), cert.get("sig")
    if not isinstance(body, dict) or not isinstance(root_id, str) or not isinstance(sig, str):
        raise Rejected("bad_certificate", "certificate has an invalid shape")
    if set(body) != CERT_FIELDS:
        raise Rejected("bad_certificate", "certificate body has unknown or missing fields")
    if body["type"] != "key_cert":
        raise Rejected("bad_certificate", "not a key certificate")
    if root_id not in roots:
        raise Rejected("untrusted_root", "certificate not issued by a registered root key of this application")
    try:
        body_bytes = canonical(body)
    except ValueError as exc:
        raise Rejected("bad_certificate", str(exc)) from exc
    if not verify_sig(roots[root_id], KEY_CERT_DOMAIN, body_bytes, sig):
        raise Rejected("bad_certificate_signature", "certificate signature does not verify")
    if body["app_id"] != app_id:
        raise Rejected("wrong_app_key", "certificate is for another application")
    if not isinstance(body["environment"], str) or not KEY_ID.fullmatch(body["environment"]):
        raise Rejected("bad_certificate", "environment is invalid")
    if environment is not None and body["environment"] != environment:
        raise Rejected("wrong_environment", f"certificate is for the {body['environment']} environment")
    roles = body["roles"]
    if not isinstance(roles, list) or not roles or not all(isinstance(r, str) and r in ROLES for r in roles):
        raise Rejected("bad_certificate", "roles must be a non-empty list of signer/approver")
    if role is not None and role not in roles:
        raise Rejected("wrong_role", f"certificate does not allow the {role} role")
    if not _is_int(body["serial"]) or not 1 <= body["serial"] < 2**63:
        raise Rejected("bad_certificate", "serial is not a positive integer")
    if not isinstance(body["key_id"], str) or not KEY_ID.fullmatch(body["key_id"]):
        raise Rejected("bad_certificate", "key_id is invalid")
    if body["serial"] in revoked.cert_serials:
        raise Rejected("revoked_certificate", f"certificate {body['serial']} is revoked")
    if body["key_id"] in revoked.key_ids:
        raise Rejected("revoked_key", f"key {body['key_id']} is revoked")
    not_before = parse_time(body["not_before"], "not_before")
    not_after = parse_time(body["not_after"], "not_after")
    if not_after <= not_before:
        raise Rejected("bad_certificate", "not_after must be after not_before")
    if role is not None and now < not_before:
        raise Rejected("certificate_not_yet_valid", "certificate is not valid yet")
    if now >= not_after:
        raise Rejected("expired_certificate", f"certificate expired at {body['not_after']}")
    if not isinstance(body["public_key"], str):
        raise Rejected("bad_certificate", "certificate public key is invalid")
    try:
        public_key = load_public_key(body["public_key"])
    except Rejected as exc:
        raise Rejected("bad_certificate", "certificate public key is invalid") from exc
    return Certificate(
        body=body, root_key_id=root_id, key_id=body["key_id"], public_key=public_key,
        public_key_b64=body["public_key"], serial=body["serial"], roles=sorted(roles),
        environment=body["environment"], not_before=not_before, not_after=not_after,
    )


# ---- manifest (schema only) --------------------------------------------------------------

_TOP = {
    "format", "app_id", "release_id", "baseline_libapp_sha256", "patch_id", "sequence", "key_id",
    "created_at", "expires_at", "runtime", "module", "packages", "host_interface", "assets", "toolchain",
}
_OPTIONAL = {"expires_at"}


def validate_manifest(m: dict) -> None:
    """Types, formats and limits. Same rules as PatchManifest.validate in Dart."""

    def bad(why: str):
        raise Rejected("bad_manifest", why)

    def string(o: dict, k: str, pattern: re.Pattern, what: str) -> str:
        v = o.get(k)
        if not isinstance(v, str) or not pattern.fullmatch(v):
            bad(f'{what} "{k}" is invalid')
        return v

    def integer(o: dict, k: str, lo: int, hi: int) -> int:
        v = o.get(k)
        if not _is_int(v) or not lo <= v <= hi:
            bad(f'integer "{k}" out of range')
        return v

    def obj(v, what: str, keys: set[str]) -> dict:
        if not isinstance(v, dict):
            bad(f"{what} is not an object")
        for k in v:
            if k not in keys:
                bad(f'unknown field "{what}.{k}"')
        for k in keys:
            if k not in v:
                bad(f'missing field "{what}.{k}"')
        return v

    for k in m:
        if k not in _TOP:
            bad(f'unknown field "{k}"')
    for k in _TOP - _OPTIONAL:
        if k not in m:
            bad(f'missing field "{k}"')
    integer(m, "format", 2, 2)
    string(m, "app_id", UUID, "uuid")
    string(m, "release_id", UUID, "uuid")
    string(m, "baseline_libapp_sha256", SHA, "sha256")
    string(m, "patch_id", UUID, "uuid")
    integer(m, "sequence", 1, 1 << 31)
    string(m, "key_id", KEY_ID, "key id")
    string(m, "created_at", ISO_UTC, "timestamp")
    if "expires_at" in m:
        string(m, "expires_at", ISO_UTC, "timestamp")
        parse_time(m["expires_at"], "expires_at", "bad_manifest")

    rt = obj(m["runtime"], "runtime", {"flutter", "dart", "engine", "abi", "runtime_id"})
    for k in rt:
        string(rt, k, VERSION, "runtime")
    mod = obj(m["module"], "module", {"format", "sha256", "size", "entry_contract"})
    if mod["format"] != "dart-bytecode":
        bad('module.format must be "dart-bytecode"')
    string(mod, "sha256", SHA, "sha256")
    integer(mod, "size", 1, MAX_CONTAINER_BYTES)
    integer(mod, "entry_contract", 1, 1000)

    pkgs = m["packages"]
    if not isinstance(pkgs, list) or len(pkgs) > 256:
        bad("packages must be a list of at most 256 entries")
    seen = set()
    for p in pkgs:
        o = obj(p, "packages[]", {"name", "module_name", "version", "source"})
        name = string(o, "name", PKG, "package name")
        string(o, "module_name", PKG, "package name")
        string(o, "version", VERSION, "version")
        if o["source"] not in ("internal", "hosted"):
            bad("packages[].source must be internal or hosted")
        if name in seen:
            bad(f'duplicate package "{name}"')
        seen.add(name)

    hi = obj(m["host_interface"], "host_interface", {"sha256", "host_packages"})
    string(hi, "sha256", SHA, "sha256")
    hp = hi["host_packages"]
    if not isinstance(hp, list) or len(hp) > 512 or any(not isinstance(e, str) or not PKG.fullmatch(e) for e in hp):
        bad("host_interface.host_packages is invalid")

    assets = m["assets"]
    if not isinstance(assets, list) or len(assets) > 1024:
        bad("assets must be a list of at most 1024 entries")
    for a in assets:
        o = obj(a, "assets[]", {"key", "sha256", "size"})
        key = o["key"]
        if (not isinstance(key, str) or not key or len(key) > 256 or key.startswith("/")
                or ".." in key or "\\" in key):
            bad("asset key is invalid")
        string(o, "sha256", SHA, "sha256")
        integer(o, "size", 0, MAX_CONTAINER_BYTES)

    tc = obj(m["toolchain"], "toolchain", {"id", *TOOLCHAIN_FIELDS})
    string(tc, "id", SHA, "sha256")
    for k in ("engine_patch_sha256", "compiler_sha256", "generator_sha256", "build_config_sha256"):
        string(tc, k, SHA, "sha256")
    for k in ("flutter", "dart", "engine", "dart_revision"):
        string(tc, k, VERSION, "version")
    integer(tc, "bytecode_format", 1, 1000)
    if hashlib.sha256(canonical({k: tc[k] for k in TOOLCHAIN_FIELDS})).hexdigest() != tc["id"]:
        raise Rejected("bad_toolchain", "toolchain id does not match its fields")


# ---- revocation lists --------------------------------------------------------------------

REVOCATION_FIELDS = {"type", "release_id", "sequence", "revoked_patch_ids", "revoked_key_ids", "revoked_cert_serials"}


@dataclass(frozen=True)
class RevocationBody:
    release_id: str
    sequence: int
    root_key_id: str
    revoked: Revoked


def parse_revocations(data: bytes, roots: dict[str, ec.EllipticCurvePublicKey] | None) -> RevocationBody:
    """A revocation container (empty module) signed by a root key. roots=None skips the signature
    check (for reading lists that were verified when they were stored)."""
    parts = split_container(data, MAX_REVOCATION_BYTES)
    if parts.module:
        raise Rejected("trailing_data", "a revocation list has no module bytes")
    body = parse_canonical(parts.manifest, "bad_revocations")
    sig = parse_canonical(parts.signature, "bad_revocations")
    if (set(body) - REVOCATION_FIELDS or body.get("type") != "revocations"
            or not isinstance(body.get("release_id"), str) or not UUID.fullmatch(body["release_id"])
            or not _is_int(body.get("sequence")) or not 1 <= body["sequence"] <= 1 << 31
            or not isinstance(body.get("revoked_patch_ids"), list)
            or not isinstance(body.get("revoked_key_ids"), list)):
        raise Rejected("bad_revocations", "invalid revocation list")
    patch_ids = body["revoked_patch_ids"]
    key_ids = body["revoked_key_ids"]
    serials = body.get("revoked_cert_serials", [])
    if any(not isinstance(p, str) or not UUID.fullmatch(p) for p in patch_ids):
        raise Rejected("bad_revocations", "invalid patch ids")
    if any(not isinstance(k, str) or not KEY_ID.fullmatch(k) for k in key_ids):
        raise Rejected("bad_revocations", "invalid key ids")
    if not isinstance(serials, list) or any(not _is_int(s) for s in serials):
        raise Rejected("bad_revocations", "invalid certificate serials")
    if set(sig) != {"alg", "key_id", "sig"} or sig["alg"] != "ES256" or not isinstance(sig["key_id"], str):
        raise Rejected("bad_signature_block", "revocation lists carry {alg, key_id, sig} only")
    if roots is not None:
        if sig["key_id"] not in roots:
            raise Rejected("untrusted_root", "revocation list not signed by a registered root key of this application")
        if not verify_sig(roots[sig["key_id"]], REVOCATION_DOMAIN, parts.manifest, sig["sig"]):
            raise Rejected("bad_signature", "revocation list signature does not verify")
    return RevocationBody(
        release_id=body["release_id"],
        sequence=body["sequence"],
        root_key_id=sig["key_id"],
        revoked=Revoked(set(patch_ids), set(key_ids), set(serials)),
    )


# ---- patch containers --------------------------------------------------------------------


@dataclass(frozen=True)
class VerifiedContainer:
    manifest: dict
    manifest_bytes: bytes
    module: bytes
    certificate: Certificate
    expires_at: datetime | None


def verify_patch_container(
    data: bytes,
    *,
    app_id: str,
    release_id: str,
    baseline_sha256: str,
    roots: dict[str, ec.EllipticCurvePublicKey],
    environment: str,
    revoked: Revoked,
    now: datetime,
) -> VerifiedContainer:
    """Everything a device would check that the server can check too. Raises Rejected.

    Not checked here (the caller does): release baseline identity, sequence order, patch_id reuse.
    """
    parts = split_container(data)
    manifest = parse_canonical(parts.manifest, "bad_manifest")
    validate_manifest(manifest)

    if manifest["app_id"] != app_id:
        raise Rejected("wrong_app", "patch is for another application")
    if manifest["release_id"] != release_id:
        raise Rejected("wrong_release", "patch is for another store release")
    if manifest["baseline_libapp_sha256"] != baseline_sha256:
        raise Rejected("wrong_baseline", "patch was built for another libapp.so")

    sig = parse_canonical(parts.signature, "bad_signature_block")
    if set(sig) - {"alg", "key_id", "sig", "cert", "approvals"} or sig.get("alg") != "ES256":
        raise Rejected("bad_signature_block", "unsupported signature block")
    if sig.get("key_id") != manifest["key_id"]:
        raise Rejected("key_mismatch", "signature key id differs from the manifest")
    if manifest["key_id"] in revoked.key_ids:
        raise Rejected("revoked_key", f"signing key {manifest['key_id']} is revoked")
    if "cert" not in sig:
        raise Rejected("certificate_required", "dbc-v1 patches must be signed by a certified key")
    cert = verify_certificate(
        sig["cert"], roots=roots, app_id=app_id, now=now, revoked=revoked,
        role="signer", environment=environment,
    )
    if cert.key_id != manifest["key_id"]:
        raise Rejected("key_mismatch", "certificate key id differs from the manifest")
    if not verify_sig(cert.public_key, MANIFEST_DOMAIN, parts.manifest, sig.get("sig")):
        raise Rejected("bad_signature", "manifest signature does not verify")

    approvals = sig.get("approvals", [])
    if not isinstance(approvals, list) or len(approvals) > 16:
        raise Rejected("bad_approval", "approvals must be a short list")
    for a in approvals:
        if not isinstance(a, dict) or set(a) - {"cert", "sig"}:
            raise Rejected("bad_approval", "approval has an invalid shape")
        ac = verify_certificate(
            a.get("cert"), roots=roots, app_id=app_id, now=now, revoked=revoked,
            role="approver", environment=environment,
        )
        if not verify_sig(ac.public_key, APPROVAL_DOMAIN, parts.manifest, a.get("sig")):
            raise Rejected("bad_approval", f"approval by {ac.key_id} does not verify")
        if ac.key_id == cert.key_id:
            raise Rejected("bad_approval", "the signer cannot approve its own patch")

    module = parts.module
    size = manifest["module"]["size"]
    if not module:
        raise Rejected("missing_module", "no module bytes")
    if len(module) > size:
        raise Rejected("trailing_data", f"{len(module) - size} bytes after the module")
    if len(module) != size:
        raise Rejected("wrong_size", f"module size {len(module)} != {size}")
    if hashlib.sha256(module).hexdigest() != manifest["module"]["sha256"]:
        raise Rejected("bad_hash", "module SHA-256 mismatch")

    if manifest["patch_id"] in revoked.patch_ids:
        raise Rejected("revoked", f"patch {manifest['patch_id']} is revoked")
    expires_at = None
    if "expires_at" in manifest:
        expires_at = parse_time(manifest["expires_at"], "expires_at", "bad_manifest")
        if now >= expires_at:
            raise Rejected("expired", f"patch expired at {manifest['expires_at']}")
    return VerifiedContainer(manifest, parts.manifest, module, cert, expires_at)
