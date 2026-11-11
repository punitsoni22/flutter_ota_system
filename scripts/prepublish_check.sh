#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Pre-publication gate. Run on a FRESH CLONE before making the repository public.
# Exits non-zero if any automated check fails. Manual items are printed at the end.
#
#   ./scripts/prepublish_check.sh            all checks, including the Docker e2e demo
#   ./scripts/prepublish_check.sh --no-e2e   skip the Docker stack (static checks only)
#
# Internal names (company, private hostnames, people) must never appear in this public file.
# Put one extended regex per line in .local/forbidden-patterns.txt (git-ignored), e.g. your
# company name, private domains and personal emails. The script greps tree AND history for them.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

fail=0
pass() { echo "[PASS] $*"; }
bad()  { echo "[FAIL] $*"; fail=1; }

say "Tracked files"
if git ls-files | grep -E '(^|/)\.env(\.[^/]*)?$' | grep -vE '\.env\.example$' | grep -q .; then
  bad ".env file is tracked: $(git ls-files | grep -E '(^|/)\.env(\.[^/]*)?$' | grep -vE '\.env\.example$' | tr '\n' ' ')"
else pass "no .env tracked"; fi
if git ls-files | grep -E '\.(pem|key|p12|pfx|jks|keystore)$' >/dev/null; then
  bad "key/certificate files tracked: $(git ls-files | grep -E '\.(pem|key|p12|pfx|jks|keystore)$' | tr '\n' ' ')"
else pass "no key/certificate files tracked"; fi
if git check-ignore -q .env; then pass ".env is git-ignored"; else bad ".env is not git-ignored"; fi
# A real key = PEM header followed by base64 body (on the next line, or after a literal \n).
PEM_RE='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----(\\n|\r?\n)[A-Za-z0-9+/=]{32,}'
has_pem() { python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1].encode(), sys.stdin.buffer.read()) else 1)' "$PEM_RE"; }
if git ls-files -z | xargs -0 cat 2>/dev/null | has_pem; then bad "private key material in tracked files"; else pass "no private key material in tracked files"; fi
if git log --all -p --no-color | has_pem; then bad "private key material in reachable history"; else pass "no private key material in reachable history"; fi

for f in LICENSE NOTICE THIRD_PARTY_NOTICES.md README.md SECURITY.md CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md .env.example; do
  if [[ -s "$f" ]]; then pass "$f present"; else bad "$f missing"; fi
done
if grep -q 'Apache License' LICENSE && grep -q 'Version 2.0, January 2004' LICENSE; then pass "LICENSE is Apache-2.0"; else bad "LICENSE is not Apache-2.0"; fi
if grep -qi 'experimental' README.md && grep -qi 'not.*production' README.md; then pass "README carries the experimental warning"; else bad "README warning missing"; fi
if grep -Eq 'YOUR_ORG|YOUR_DOMAIN' SECURITY.md CODE_OF_CONDUCT.md .github/ISSUE_TEMPLATE/config.yml 2>/dev/null; then
  bad "placeholders (YOUR_ORG / YOUR_DOMAIN) left in SECURITY.md / CODE_OF_CONDUCT.md / issue config"
else pass "contact placeholders replaced"; fi

say ".env.example values are fake"
if grep -Ev '^\s*(#|$)' .env.example | grep -Eiv 'not-a-secret|local-dev|^FLUTTER_OTA_|^POSTGRES_(USER|DB)=|^OTA_(ENV|CDN_BASE_URL|SERVE_ARTIFACTS_LOCALLY|SIGNING_KEY_ID|AUTO_GENERATE_SIGNING_KEY)=' | grep -q .; then
  bad "unexpected value in .env.example:"; grep -Ev '^\s*(#|$)' .env.example | grep -Eiv 'not-a-secret|local-dev|^FLUTTER_OTA_|^POSTGRES_(USER|DB)=|^OTA_(ENV|CDN_BASE_URL|SERVE_ARTIFACTS_LOCALLY|SIGNING_KEY_ID|AUTO_GENERATE_SIGNING_KEY)='
else pass ".env.example contains only placeholders"; fi

say "Internal identifiers (from .local/forbidden-patterns.txt)"
if [[ -s .local/forbidden-patterns.txt ]]; then
  if git grep -I -n -i -E -f .local/forbidden-patterns.txt -- . >/dev/null; then
    bad "forbidden pattern in tracked files:"; git grep -I -n -i -E -f .local/forbidden-patterns.txt -- . | cut -c1-160 | head -20
  else pass "no forbidden patterns in tracked files"; fi
  hits="$(git log --all -p --format='%H %an <%ae> %cn <%ce>' | grep -i -c -E -f .local/forbidden-patterns.txt || true)"
  if [[ "$hits" != "0" ]]; then bad "forbidden patterns appear $hits time(s) in history (content or author/committer metadata)"; else pass "no forbidden patterns in history"; fi
else
  echo "[SKIP] create .local/forbidden-patterns.txt to check internal names (strongly recommended)"
fi

say "Secret scan (gitleaks, working tree + full history)"
need_docker
if docker run --rm -v "$ROOT:/repo:ro" zricethezav/gitleaks:v8.21.2 git /repo --redact --no-banner --exit-code 1 >/dev/null 2>&1; then
  pass "gitleaks: history clean"; else bad "gitleaks found leaks in history (run it without >/dev/null to see redacted findings)"; fi
if docker run --rm -v "$ROOT:/repo:ro" zricethezav/gitleaks:v8.21.2 dir /repo --redact --no-banner --exit-code 1 >/dev/null 2>&1; then
  pass "gitleaks: working tree clean"; else bad "gitleaks found leaks in the working tree (including untracked files)"; fi

say "Compose"
if compose config -q; then pass "docker compose config valid"; else bad "docker compose config invalid"; fi

say "Backend tests (container)"
if docker run --rm -v "$ROOT/backend:/src:ro" python:3.13-slim sh -c \
    "cp -r /src /tmp/b && cd /tmp/b && pip install -q --root-user-action=ignore -r requirements-dev.txt >/dev/null 2>&1 && python -m pytest -q" ; then
  pass "backend tests"; else bad "backend tests"; fi

if command -v flutter >/dev/null 2>&1; then
  say "Flutter"
  if (cd packages/ota_client && flutter pub get >/dev/null && flutter analyze && flutter test); then pass "ota_client analyze + test"; else bad "ota_client analyze/test"; fi
  if (cd example_app && flutter pub get >/dev/null && flutter analyze); then pass "example_app analyze"; else bad "example_app analyze"; fi
else
  echo "[SKIP] flutter not installed"
fi

if [[ "${1:-}" != "--no-e2e" ]]; then
  say "End-to-end demo on a fresh stack"
  [[ -f .env ]] || cp .env.example .env
  ./scripts/cleanup_local.sh --yes >/dev/null 2>&1 || true
  if ./scripts/setup_local.sh && ./scripts/seed_demo.sh && ./scripts/publish_test_patch.sh && ./scripts/verify_demo.sh; then
    pass "fresh stack: migrations, seed, publish, register, check, download, SHA-256, signature, negatives, rollback, revoke"
  else bad "end-to-end demo"; fi
fi

cat <<'EOF'

Manual items (cannot be automated here; see docs/release/PREPUBLISH_CHECKLIST.md and docs/release/MANUAL_SECURITY_CHECKLIST.md):
  [ ] Every secret in .local/release/SECRET_ROTATION_CHECKLIST.md (private, not committed) rotated or confirmed never exposed
  [ ] History decision made and executed (.local/release/history-cleanup.md, private), incl. author emails
  [ ] GitHub private vulnerability reporting enabled; security contact monitored
  [ ] Quickstart completed on another machine using README only
  [ ] Release notes (docs/release/v0.1.0-alpha.1.md) reviewed; tag created as a PRE-release
EOF

echo
if [[ "$fail" -ne 0 ]]; then echo "PREPUBLISH: FAILED (do not make the repository public)"; exit 1; fi
echo "PREPUBLISH: automated checks passed (complete the manual items before publishing)"
