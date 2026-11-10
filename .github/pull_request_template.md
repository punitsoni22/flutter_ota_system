## What and why

<!-- What does this change, and which issue does it address? -->

Closes #

## How it was tested

- [ ] `cd backend && python -m pytest -q`
- [ ] `flutter analyze && flutter test` in `packages/ota_client` (if Dart changed)
- [ ] `./scripts/verify_demo.sh` on a fresh `./scripts/setup_local.sh` (if API/Docker changed)
- [ ] Other:

## Security impact

<!-- Does this touch signing, verification, the canonical message, rollout, auth, storage URLs,
     secrets handling or the patch format? If yes, explain the impact. -->

- [ ] No security-relevant change
- [ ] Security-relevant change, explained above

## Checklist

- [ ] No secrets, keys, `.env` files, internal URLs or personal data are added
- [ ] Backend **and** `ota_client` are updated together if the protocol changed
- [ ] Docs and `CHANGELOG.md` (Unreleased) are updated
- [ ] Any code copied from another project is identified with its licence
