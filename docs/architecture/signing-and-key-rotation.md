# Signing identities, key rotation and revocation (Phase 3C prototype)

Status: experimental prototype in `prototypes/security_hardening` (`package:patch_security`,
`tools/sign_patch.py`). It is **not** the production signing protocol (`backend/app/signing.py` and
the production SDK are unchanged). Android only.

## 1. Key hierarchy

```text
APP ROOT KEY (one per application, kept OFFLINE; public key compiled into the store build)
   │  issues key certificates (ES256), never signs patches
   ├── signer certificate   {app_id, environment, key_id, public_key, roles:[signer],   serial, not_before, not_after}
   │      └── developer's local signing key  ──signs──> patch manifest
   └── approver certificate {…, roles:[approver], …}
          └── approver key ──signs──> approval of the same manifest bytes
```

| Concept | Rule (enforced on the device by `verifyCertificate` / `verifyCertifiedSignature`) |
| --- | --- |
| Per-application identity | The certificate's `app_id` must equal the app's id (`wrong_app_key`); only the roots compiled into **this** app are trusted (`untrusted_root`). |
| Environment | A `development` certificate is refused by a `production` build and vice versa (`wrong_environment`). |
| Roles | A signer key needs `signer`; an approver needs `approver` (`wrong_role`). |
| Validity | `not_before` / `not_after` in UTC (`certificate_not_yet_valid`, `expired_certificate`). |
| Local developer signing | The signer key lives on the developer's machine (lab dir, mode 600 in this prototype). The backend never holds it. |
| Approvals | A build may require N approvals (`requiredApprovals`). Each approval is an approver signature over the **same manifest bytes**, from a distinct key that is not the signer (`approval_required`, `bad_approval`). |
| Domain separation | Certificates, approvals, manifests and revocation lists are signed over different domain prefixes, so one kind of signature can never be replayed as another. |

## 2. Rotation, revocation, emergency replacement

- **Rotation** (planned): the root issues a certificate with a **new serial** for the new key. Devices
  accept the new key immediately; no new store build is needed. The old key is then retired by
  revoking its serial.
- **Revocation**: a revocation list signed by the **root** (or, as in Phase 3, a directly trusted key)
  lists `revoked_patch_ids`, `revoked_key_ids` and `revoked_cert_serials`. Lists have a sequence
  number; an older or equal sequence is refused (`replay`). Revoked serials and key ids are stored on
  the device and checked for every later patch (`revoked_certificate`, `revoked_key`).
- **Emergency replacement** (signer key stolen): revoke the stolen key's serial (and key id) with a
  root-signed list, certify a replacement key, re-sign the current patch with it. A stolen signer key
  cannot certify another key (`untrusted_root`: only roots issue certificates) and cannot revoke
  anything (not a root).
- **Root key compromise** is **not** recoverable over the air in this design: the roots are compiled
  into the store build. Recovery needs a new store release with new roots. This is why the root key
  must stay offline and only signs certificates and revocation lists.

## 3. Commands (prototype)

```bash
T=prototypes/security_hardening/tools/sign_patch.py
KEYS=~/.cache/flutter-ota-lab/keys/p3            # private keys never go into the repository

# one-time: root key (offline) and a developer key
python3 -I $T keygen --dir $KEYS --key-id p3-root
python3 -I $T keygen --dir $KEYS --key-id p3-signer-a

# root certifies the developer key for this app and environment
python3 -I $T issue-cert --root $KEYS/p3-root.pem --root-key-id p3-root --app-id <app-uuid> \
  --environment development --pub $KEYS/p3-signer-a.pub --key-id p3-signer-a --roles signer \
  --serial 101 --not-before 2026-11-01T00:00:00Z --not-after 2027-11-01T00:00:00Z --out cert_a.json

# developer signs a patch locally with the certified key
python3 -I $T sign --key $KEYS/p3-signer-a.pem --key-id p3-signer-a --cert cert_a.json ... --out patch.otp

# optional approval (approver key with an approver certificate), attached to the patch file
python3 -I $T approve --key $KEYS/p3-approver.pem --cert cert_approver.json --patch patch.otp --out approval.json --attach

# retire / emergency-revoke certificate 101 (root-signed revocation list)
python3 -I $T revoke --key $KEYS/p3-root.pem --key-id p3-root --release <release-uuid> --sequence 2 \
  --revoke-cert-serial 101 --out revocations.otp
```

## 4. Tests

Linux unit tests (`packages/patch_security/test/cert_test.dart`), all required cases:

| Required case | Test | Expected code |
| --- | --- | --- |
| wrong app key | certificate for another app / another app's root | `wrong_app_key` / `untrusted_root` |
| wrong environment key | development certificate in a production build | `wrong_environment` |
| revoked key | key id revoked | `revoked_key` |
| expired key | certificate past `not_after` (and not yet valid) | `expired_certificate` / `certificate_not_yet_valid` |
| unauthorised rotation | signer key certifies another key | `untrusted_root` |
| replayed rotation | stolen old certificate whose serial was revoked | `revoked_certificate` |
| invalid approval | approval of another manifest, own approval, approver without role, missing approval | `bad_approval` / `wrong_role` / `approval_required` |
| old key after revocation | old certificate used after its serial was revoked | `revoked_certificate` |

Device tests (cert suite of `scripts/device_suite_p3.py`), run on 2026-11-12 on an Android 13
arm64 phone (release build with the patched engine). **All passed:**

| Case | Result on the phone |
| --- | --- |
| certified patch | accepted |
| other environment | `wrong_environment` |
| certificate signed by another root | `bad_certificate_signature` |
| unauthorised rotation | `untrusted_root` |
| uncertified new key | `unknown_key` |
| other compiler | `wrong_toolchain` |
| forged toolchain id | `bad_toolchain` |
| rotation to a new certified key | accepted, without a new store build |
| old key after a root-signed revocation of its serial | `revoked_certificate` |
| replayed revocation list | `replay` |

None of the rejected files reached the verifier process. The same signed files were also checked on
Linux against `package:patch_security` (Python signer -> Dart verifier): every expected result
matched ([phase-3-final-security-report.md](phase-3-final-security-report.md), section E).

## 5. Limits

- Prototype key storage is a lab directory with file permissions; real deployments need hardware
  protection for the root (offline HSM or smart card) and for developer keys.
- The prototype build still accepts the Phase 3 directly trusted keys (`requireCertificates: false`)
  so older test artifacts keep working; a production design would require certificates.
- Device time is used for certificate validity; a device with a wrong clock may refuse or accept
  certificates at the edges of their validity. Revocation does not depend on time.
- Approvals were tested on Linux only; the device build requires 0 approvals.
