"""ES256 signing (ADR-0002). Signatures are raw r||s (64 bytes), base64-encoded.

The local PEM signer is for development. Phase 10 swaps in a Key Vault signer with the same interface.
"""

import base64
from pathlib import Path
from typing import Protocol

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    decode_dss_signature,
    encode_dss_signature,
)


class Signer(Protocol):
    key_id: str

    def sign(self, message: bytes) -> str: ...

    def public_key(self) -> ec.EllipticCurvePublicKey: ...


class LocalSigner:
    def __init__(self, private_key: ec.EllipticCurvePrivateKey, key_id: str):
        self._key = private_key
        self.key_id = key_id

    @classmethod
    def from_file(cls, path: Path, key_id: str, generate: bool) -> "LocalSigner":
        if not path.exists():
            if not generate:
                raise RuntimeError(f"Signing key not found: {path}")
            path.parent.mkdir(parents=True, exist_ok=True)
            key = ec.generate_private_key(ec.SECP256R1())
            path.write_bytes(
                key.private_bytes(
                    serialization.Encoding.PEM,
                    serialization.PrivateFormat.PKCS8,
                    serialization.NoEncryption(),
                )
            )
            path.chmod(0o600)
        return cls.from_pem(path.read_bytes(), key_id)

    @classmethod
    def from_pem(cls, pem: bytes, key_id: str) -> "LocalSigner":
        """For hosts without a disk: the key comes from a secret (OTA_SIGNING_KEY_PEM)."""
        key = serialization.load_pem_private_key(pem.replace(b"\\n", b"\n"), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
            raise RuntimeError("Signing key must be an EC P-256 private key")
        return cls(key, key_id)

    def sign(self, message: bytes) -> str:
        der = self._key.sign(message, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        return base64.b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode()

    def public_key(self) -> ec.EllipticCurvePublicKey:
        return self._key.public_key()


def verify(public_key: ec.EllipticCurvePublicKey, message: bytes, signature_b64: str) -> bool:
    raw = base64.b64decode(signature_b64)
    if len(raw) != 64:
        return False
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    try:
        public_key.verify(der, message, ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


def public_key_info(signer: Signer) -> dict:
    """The forms of the public key that apps embed. Dart uses the uncompressed point."""
    pub = signer.public_key()
    point = pub.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    pem = pub.public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()
    return {
        "key_id": signer.key_id,
        "algorithm": "ES256",
        "uncompressed_point_base64": base64.b64encode(point).decode(),
        "pem": pem,
    }
