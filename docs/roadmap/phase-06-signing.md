# Phase 6 — Cryptographic trust (2–4 pw) → Milestone C

> **Roadmap status: 🟡 partial.**
> - ✅ Canonical encoder in Python and Dart with a shared test vector, local PEM signer, public key
>   export (`GET /v1/admin/signing-key`, `ota key show`), Dart verification against a **set** of
>   trusted keys, tamper tests (`scripts/verify_demo.sh`).
> - 🔭 **Azure Key Vault signer (6.4) is not implemented.** There is no key rotation runbook
>   (6.10) yet.

**Goal:** the phone only accepts patches signed by **your** private key, and that key never leaves Azure Key Vault.

**Why a hash isn't enough:** the hash proves the file matches what the server said. If an attacker controls the server response (or your database), they can send a malicious file with a matching hash. A signature proves the patch came from someone holding your private key.

Read [ADR-0002](../adr/0002-signature-scheme.md) first. This phase implements it.

Branch: `git switch -c phase-6-signing`.

---

## 6.1 Canonical encoder in Python

**Do:** `backend/app/signing/canonical.py` (the `patch_engine` CLI imports the same module):

```python
import struct
from dataclasses import dataclass

PREFIX = b"OTA-PATCH-V1\n"


@dataclass(frozen=True)
class SignedFields:
    application_id: str
    release_id: str
    patch_number: int
    platform: str
    arch: str
    runtime_abi: str
    artifact_format: str
    base_artifact_sha256: str
    payload_sha256: str
    result_sha256: str
    size_bytes: int


def encode(fields: SignedFields) -> bytes:
    parts = [
        "1",
        fields.application_id,
        fields.release_id,
        str(fields.patch_number),
        fields.platform,
        fields.arch,
        fields.runtime_abi,
        fields.artifact_format,
        fields.base_artifact_sha256,
        fields.payload_sha256,
        fields.result_sha256,
        str(fields.size_bytes),
    ]
    out = bytearray(PREFIX)
    for part in parts:
        data = part.encode("utf-8")
        out += struct.pack(">I", len(data)) + data
    return bytes(out)
```

**Check:** a unit test with the ADR test vector: `len == 371` and `sha256(...).hexdigest() == "2c53f97238a44c3bc7262a54e8c7ecd8e9ea105aa0b3c4fdc105fe38e78a8a79"`.

---

## 6.2 Canonical encoder in Dart

**Do:** `packages/ota_protocol/lib/src/canonical.dart`, the same logic with `BytesBuilder`:

```dart
import 'dart:convert';
import 'dart:typed_data';

Uint8List encodeSignedFields(List<String> parts) {
  final builder = BytesBuilder()..add(ascii.encode('OTA-PATCH-V1\n'));
  for (final part in parts) {
    final data = utf8.encode(part);
    final length = ByteData(4)..setUint32(0, data.length, Endian.big);
    builder
      ..add(length.buffer.asUint8List())
      ..add(data);
  }
  return builder.toBytes();
}
```

Wrap it in a typed function that takes the manifest fields in the ADR order.

**Check:** the **same** test vector passes in Dart. If Python and Dart disagree, stop and fix it before going on.

---

## 6.3 Signer interface + local signer

**Why:** use a local key file for development and tests, and Key Vault in real environments. The same interface serves both.

**Do:** `backend/app/signing/signer.py`:

```python
import hashlib
from typing import Protocol

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


class Signer(Protocol):
    key_id: str

    async def sign(self, message: bytes) -> bytes: ...  # returns raw 64-byte r||s


def der_to_raw(der: bytes) -> bytes:
    r, s = decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


class LocalSigner:
    """Development only. Never use in production."""

    def __init__(self, key_id: str, private_key_pem: bytes):
        self.key_id = key_id
        self._key = serialization.load_pem_private_key(private_key_pem, password=None)

    async def sign(self, message: bytes) -> bytes:
        return der_to_raw(self._key.sign(message, ec.ECDSA(hashes.SHA256())))
```

Generate a dev key once (`*.pem` is already in `.gitignore`):

```bash
openssl ecparam -name prime256v1 -genkey -noout -out dev-signing-key.pem
```

Add `"cryptography>=43"` to dependencies.

---

## 6.4 Key Vault signer

**Do:** add `"azure-keyvault-keys>=4.9"`, then:

```python
from azure.identity.aio import DefaultAzureCredential
from azure.keyvault.keys.crypto import SignatureAlgorithm
from azure.keyvault.keys.crypto.aio import CryptographyClient


class KeyVaultSigner:
    def __init__(self, key_id: str, key_uri: str):
        self.key_id = key_id
        self._client = CryptographyClient(key_uri, DefaultAzureCredential())

    async def sign(self, message: bytes) -> bytes:
        digest = hashlib.sha256(message).digest()          # Key Vault signs a digest
        result = await self._client.sign(SignatureAlgorithm.es256, digest)
        return result.signature                             # already raw r||s
```

Creating the key (Phase 10 automates this):

```bash
az keyvault key create --vault-name <vault> --name patch-signing --kty EC --curve P-256 --protection hsm
```

`DefaultAzureCredential` uses `az login` on your laptop and managed identity in Azure. No secrets in code.

---

## 6.5 Exporting the public key for the app

**Why:** the app embeds the public key. The simplest format for Dart is the uncompressed EC point (65 bytes: `04 || X || Y`), base64-encoded.

**Do:** a CLI command `ota-patch export-public-key` that prints:

```python
key.public_key().public_bytes(serialization.Encoding.X962,
                              serialization.PublicFormat.UncompressedPoint)
```

For Key Vault keys: `KeyClient.get_key(...)` returns `x` and `y`, so build `b"\x04" + x + y`.

Store the result in the app as a **key set** ([ADR-0007](phase-00-protocol-decisions.md)):

```dart
const trustedKeys = <String, String>{
  'signing-key-2026-01': 'BHx...base64...',
};
```

---

## 6.6 Verification in Dart

**Do:** add `pointycastle` to `ota_protocol` (or `ota_client`):

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

bool verifyEs256({
  required Uint8List publicKeyUncompressed, // 65 bytes
  required Uint8List message,
  required Uint8List signatureRaw,          // 64 bytes r||s
}) {
  if (signatureRaw.length != 64) return false;
  final curve = ECCurve_secp256r1();
  final point = curve.curve.decodePoint(publicKeyUncompressed);
  final signer = Signer('SHA-256/ECDSA')
    ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(point, curve)));
  BigInt toBigInt(Uint8List b) =>
      b.fold(BigInt.zero, (acc, byte) => (acc << 8) | BigInt.from(byte));
  final r = toBigInt(signatureRaw.sublist(0, 32));
  final s = toBigInt(signatureRaw.sublist(32));
  try {
    return signer.verifySignature(message, ECSignature(r, s));
  } catch (_) {
    return false; // malformed input is simply "not verified"
  }
}
```

---

## 6.7 Cross-language golden test

**Why:** the only way to be sure Python-signed means Dart-verifiable.

**Do:**
1. A Python script signs the ADR test message with a **test-only** key and writes `packages/ota_protocol/test/fixtures/es256_vector.json` (`public_key`, `message_hex`, `signature_b64`).
2. A Dart test loads it and asserts `verifyEs256(...) == true`. It also asserts `false` for a flipped message byte and a flipped signature byte.

---

## 6.8 Wire signing into the pipeline

**Server:**
- `signing_keys` rows hold `key_id`, algorithm, public key, and status (`active`/`retiring`/`revoked`).
- `POST /v1/admin/patches/{id}/validate` rebuilds the canonical message from the **database** values, verifies the stored signature with the stored public key, and checks the key is `active` or `retiring`. Only then does it move the patch to `validated`.

**CLI:** `ota-patch upload` gains `--sign local|keyvault` and sends `signature`, `signature_algorithm` and `key_id` on commit.

**Client:** the order matters:

```
download → hash check → rebuild canonical message from the manifest
         → key_id in trustedKeys? → verifyEs256 → stagePatch
```

Also re-verify the signature at **boot** before activating (5.7). The disk is untrusted too.

**Anti-replay ([ADR-0006](phase-00-protocol-decisions.md)):** refuse any patch whose `patch_number` ≤ the highest number ever installed, unless it equals `rollback_to_patch_number`.

---

## 6.9 Tamper test suite

**Do:** client tests, each expecting rejection **and** the right telemetry code:

| Attack | Expected |
|---|---|
| Flip one byte of the payload | `patch_hash_failed` |
| Truncate the payload | `patch_download_failed` / hash failed |
| Valid file, signature by an unknown key | `patch_signature_failed` |
| Signature for release A served to release B | `patch_signature_failed` |
| Right release, wrong arch | `patch_signature_failed` |
| Old valid patch replayed | rejected (anti-replay) |
| Revoked patch | rejected |
| `state.json` points at a tampered file on disk | fallback at boot |

---

## 6.10 Key rotation runbook

**Do:** write `docs/security/key-rotation.md`:
1. Create a new Key Vault key version or key.
2. Add its public key to `trustedKeys` and ship a store release. The old key stays trusted.
3. When most users are on that release, start signing with the new key and mark the old one `retiring`.
4. After the old releases age out, mark the old key `revoked`.

Also cover the emergency case (a key is compromised): revoke all patches signed by it and ship a store release without it.

---

## Phase 6 is done when

- [ ] Python and Dart agree on the test vector and the ES256 golden signature
- [ ] The server refuses to validate a patch with a bad signature
- [ ] Every tamper case is rejected on-device
- [ ] A Key Vault-signed patch installs. 🎉 **Milestone C**
