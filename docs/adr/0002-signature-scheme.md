# ADR-0002: Patch signature scheme and canonical encoding

- **Status:** Proposed
- **Date:** 2026-09-30

## Context

The server (Python), the signing CLI (Python) and the client (Dart) must all produce exactly the same bytes to sign and verify. Signing "the JSON" does not work, because each language serialises JSON differently. The blueprint's `a || b || c` concatenation is ambiguous: `"ab" || "c"` and `"a" || "bc"` give the same bytes. The private key must stay in Azure Key Vault.

## Decision

**Algorithm:** ECDSA with curve P-256 and SHA-256 (JOSE name `ES256`). Supported natively by Azure Key Vault, 64-byte signatures, verifiable in Dart with `pointycastle`.

**Signature encoding:** raw 64 bytes `r || s` (32 bytes each, big-endian), then base64 (standard alphabet, with padding). This is what Key Vault returns. Python's `cryptography` library uses DER, so convert with `encode_dss_signature` / `decode_dss_signature`.

**Signed message** (the "canonical encoding"):

```
message = ASCII("OTA-PATCH-V1\n")
        + for each field, in this exact order:
            uint32 big-endian byte length of the UTF-8 field
            + the UTF-8 bytes of the field
```

Fields, all as strings:

| # | Field | Example |
|---|---|---|
| 1 | protocol_version | `"1"` |
| 2 | application_id | `"6f629161-5d63-4caa-9174-0ad1b225ad37"` |
| 3 | release_id | `"7b831760-d896-433e-a4d2-825234657044"` |
| 4 | patch_number (decimal) | `"3"` |
| 5 | platform | `"android"` |
| 6 | arch | `"arm64-v8a"` |
| 7 | runtime_abi | `"ota-runtime-v1"` |
| 8 | artifact_format | `"mock-v1"` |
| 9 | base_artifact_sha256 (lowercase hex) | 64 chars |
| 10 | payload_sha256 (lowercase hex) | 64 chars |
| 11 | result_sha256 (lowercase hex) | 64 chars |
| 12 | size_bytes (decimal) | `"1834241"` |

`signature = ES256_sign(private_key, message)`. The signer hashes the message with SHA-256. With Key Vault, you compute `SHA-256(message)` locally and send that 32-byte digest to Key Vault's `sign` operation with algorithm `ES256`.

**Test vector.** With the example values above and `"a"*64`, `"b"*64`, `"c"*64` for the three hashes:

- `len(message)` = **371** bytes
- `SHA-256(message)` = `2c53f97238a44c3bc7262a54e8c7ecd8e9ea105aa0b3c4fdc105fe38e78a8a79`

Both the Python and Dart encoders must have a unit test asserting this exact value.

## Consequences

- Good: no ambiguity, and it is easy to implement identically in any language.
- Good: the signature binds the patch to one application, release, platform and architecture (prevents cross-release replay).
- Bad: adding a field requires `OTA-PATCH-V2`. Old clients keep verifying V1.

## Alternatives considered

- RSA-PSS-SHA256: works, but signatures are 256+ bytes and verification in Dart is slower.
- Ed25519: nice, but not supported by Azure Key Vault.
- Canonical JSON (RFC 8785): works, but it is easy to get subtly wrong across languages.
