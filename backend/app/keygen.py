# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Create the ES256 patch-signing key once.

    python -m app.keygen          on the server: writes the key file (VPS with a disk)
    python -m app.keygen --pem    anywhere: prints the key for the OTA_SIGNING_KEY_PEM secret (cloud)

Also prints the public key for the apps (OTA_PUBLIC_KEY). Never replace a key in use: apps in the
field trust only that key, so replacing it means shipping new store builds.
"""

import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import get_settings
from app.signing import LocalSigner, public_key_info


def main() -> None:
    s = get_settings()
    if "--pem" in sys.argv:
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        ).decode()
        info = public_key_info(LocalSigner(key, s.signing_key_id))
        print("OTA_SIGNING_KEY_PEM (one line; keep it secret, back it up):")
        print(pem.strip().replace("\n", "\\n"))
        print(f"\nOTA_PUBLIC_KEY for the apps: {info['key_id']}:{info['uncompressed_point_base64']}")
        return
    if s.signing_key_path.exists():
        sys.exit(f"{s.signing_key_path} already exists; not replacing it")
    signer = LocalSigner.from_file(s.signing_key_path, s.signing_key_id, generate=True)
    info = public_key_info(signer)
    print(f"Created {s.signing_key_path}. BACK IT UP somewhere safe and offline.")
    print(f"OTA_PUBLIC_KEY for the apps: {info['key_id']}:{info['uncompressed_point_base64']}")


if __name__ == "__main__":
    main()
