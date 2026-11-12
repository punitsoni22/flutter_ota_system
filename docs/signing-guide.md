<!-- Copyright 2026 The Punit Authors -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Signing guide: how `flutter_ota patch android` signs a patch

Status: experimental alpha. Android only. The design is in
[signing-and-key-rotation.md](architecture/signing-and-key-rotation.md) and the server side in
[architecture/phase-4-backend-protocol.md](architecture/phase-4-backend-protocol.md).

## 1. Who signs what

```text
app ROOT key            keep it offline; its public key is compiled into your app
  └── signs a CERTIFICATE for your signer key (app, environment, role "signer", validity)
        └── your SIGNER key signs each patch, on your own machine
```

The server never signs `dbc-v1` patches and never sees a private key. It checks the signature
when you upload, and the phone checks it again before it runs the patch.

## 2. Where the keys are

Keys are created by `flutter_ota keys` and live outside every project:

```text
~/.config/flutter_ota/keys/<app_id>/
  roots/<key_id>.key          ROOT private key (mode 600). Keep it offline when you can.
  roots/<key_id>.pub
  signers/<key_id>.key        signer private key (mode 600)
  signers/<key_id>.pub
  signers/<key_id>.cert.json  certificate issued by the root key (public)
```

`FLUTTER_OTA_CONFIG_DIR` or `FLUTTER_OTA_KEYS_DIR` move this folder (for CI).

Never commit these files. Never paste a private key into a chat, a ticket or a log.

## 3. Which key the patch command uses

It picks the newest signer certificate that is:

- for this app (`app_id` in `flutter_ota.yaml`);
- for the release's environment (`production` or another name used at release time);
- valid now (between `not_before` and `not_after`);

and then refuses to sign when:

- the private key file can be read by other users (fix: `chmod 600 <file>`);
- the certificate does not have the `signer` role, or certifies another public key;
- the certificate was not issued by one of the root keys compiled into this release.

These are the same checks the phone makes, so a patch the phone would refuse is never signed.

## 4. What is signed

The patch file is one `OTAPRT02` container:

```text
"OTAPRT02" | manifest length | manifest (canonical JSON)
           | signature length | {"alg":"ES256","cert":{...},"key_id":"...","sig":"..."}
           | module bytes (Dart bytecode)
```

- `sig` is ES256 (P-256 + SHA-256), raw `r||s`, base64, over
  `"flutter-ota-system/patch-manifest/v2\n" + manifest bytes`. The prefix means a patch
  signature can never be reused as another kind of signature.
- The manifest contains the module's SHA-256 and size, so the signature covers the module too.
- Before writing the file, the CLI checks the manifest against the schema of
  `package:patch_security`, verifies its own signature with the certified key and re-reads the
  container. A test verifies CLI-signed patches with `patch_security`'s `verifyPatch`.

## 5. Rotation and a lost key

- **New signer key (planned rotation):** create a new signer certificate with
  `flutter_ota keys`. Patches use it at once; no new store release is needed.
- **Signer key stolen:** revoke its certificate serial with a revocation list signed by the
  root key, then create a new signer key. See
  [signing-and-key-rotation.md](architecture/signing-and-key-rotation.md).
- **Root key lost or stolen:** this needs a new store release with a new root key.

## 6. Troubleshooting

| Message | What to do |
| --- | --- |
| `No certified patch-signing key for app ...` | run `flutter_ota keys init` (or get a signer certificate from whoever holds the root key) |
| `... can be read by other users` | `chmod 600 <the key file>` |
| `the certificate is for the development environment, but the release is production` | create a signer certificate for the release's environment |
| `... which this release does not trust` | the certificate's root key is not compiled into this release; use a certificate from one of its roots |
| `the certificate expired at ...` | create a new signer certificate |
