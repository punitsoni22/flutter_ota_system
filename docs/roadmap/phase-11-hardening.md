# Phase 11 — Scale and security hardening (4–6 pw) → Milestone G

> **Roadmap status: 🔭 mostly planned.**
> - **The 1M-installs scale target is a design goal. No load test has been run, and Punit makes no
>   capacity claim.**
> - 🟡 Partly there: a secret scan (gitleaks) and a licence gate in CI (11.7); a backup script for
>   the single-server setup (`deploy/backup.sh`, 11.8); a threat overview in
>   [security.md](../security.md) (11.6).
> - 🔭 Not built: load tests (11.1, 11.3), the **Redis** decision (11.2), chaos tests (11.4, 11.5)
>   and the cost model (11.9).

**Goal:** prove, with numbers, that the system survives 1M devices, crashes at any moment, and your own mistakes.

**New concepts:** load testing, chaos testing, threat modelling, disaster recovery drills.

Branch: `git switch -c phase-11-hardening`.

---

## 11.1 Load test the update check

**Why:** the design goal's danger case (**not tested yet**) is 1M devices checking within minutes, which is up to 16,667 requests/second. Targets: **5,000 sustained / 10,000 burst RPS** on `/v1/updates/check`.

**Do:**
1. Install k6 (see the setup guide).
2. Pre-create 50,000 test devices with a script and save their tokens to a file.
3. `loadtest/check.js`:

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

const devices = new SharedArray('devices', () => JSON.parse(open('./devices.json')));

export const options = {
  scenarios: {
    sustained: { executor: 'constant-arrival-rate', rate: 5000, timeUnit: '1s',
                 duration: '10m', preAllocatedVUs: 2000 },
  },
  thresholds: {
    http_req_failed: ['rate<0.001'],
    http_req_duration: ['p(95)<250'],
  },
};

export default function () {
  const d = devices[Math.floor(Math.random() * devices.length)];
  const res = http.get(`${__ENV.API}/v1/updates/check?release_id=${d.release_id}` +
      `&current_patch_number=0&platform=android&arch=arm64-v8a&channel=production`,
      { headers: { Authorization: `Bearer ${d.token}` } });
  check(res, { 'status 200': (r) => r.status === 200 });
}
```

4. Run it against a **staging** environment sized like production, never production itself. A single laptop can't generate 10k RPS, so use **Azure Load Testing** (it runs k6/JMeter scripts) or several VMs.
5. Watch: replicas count, CPU per replica, Postgres CPU and connections, p95 latency.

**Output:** a short report `docs/operations/load-test-<date>.md`: requests per replica, final scale settings, bottlenecks found.

---

## 11.2 Decide on Redis

**Do:** if Postgres CPU is high during the load test and the deployment head query dominates, add Azure Managed Redis as the head cache (and use pub/sub for instant invalidation). If not, **don't add it**. Record the decision in an ADR.

---

## 11.3 Load test telemetry and the CDN

**Do:**
- `/v1/events/batch` at 5,000–10,000 events/second (in batches of 20–50). Check Event Hubs throughput units and worker lag.
- CDN: download one 2 MB patch 10,000 times from several regions. Check the Front Door cache hit ratio (target > 95%) and that storage origin requests stay low.

---

## 11.4 Client chaos tests

**Why:** the rule is "the store version must always boot." Prove it.

**Do:** an integration test harness (Flutter `integration_test` or a Dart test around the client with a fake runtime) that **kills the process** at each point:

| Kill during | Next start must be |
|---|---|
| Download | Previous active or store version. Temp file cleaned |
| Hash verify | Same |
| Signature verify | Same |
| Staging (copy/rename) | Same |
| Writing `state.json` | Same (atomic rename) |
| First boot of new patch (before confirm) | Auto-rollback to last good |

Also test: disk full, `state.json` corrupted, patch file deleted from disk, clock set far in the past or future.

Kill points can be injected with a test-only hook (`onStep(step)` that throws).

---

## 11.5 Backend failure tests

**Do:** in staging, one at a time:
- Stop Postgres (or block it) → check returns a safe response or 503 quickly, and the app keeps working.
- Break Event Hubs → `/events/batch` returns 503, and clients back off.
- Block Blob → downloads fail, clients back off, and nothing is corrupted.
- Kill API replicas during the load test → error rate stays within SLO.

---

## 11.6 Threat model

**Do:** `docs/threat-model/README.md` using **STRIDE** (Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of privilege). For each, list threats and your mitigation. At minimum:

| Threat | Mitigation |
|---|---|
| Stolen signing key | Key Vault HSM, key never exported, key rotation, revoke runbook |
| Malicious insider publishes a patch | Production approval, two-person rule, audit trail |
| Compromised CDN serves a bad file | Signature verification on device |
| Stolen device refresh token | Rotation + reuse detection |
| Replay of an old signed patch | Anti-replay rule, signature binds release and number |
| DoS on register/check | WAF rate limits, autoscale, jitter |
| Admin account takeover | Entra ID MFA / Conditional Access, least-privilege roles |

---

## 11.7 Security scanning in CI

**Do:** add `.github/workflows/security.yml`:
- **CodeQL** for Python (GitHub → Security → Code scanning → set up)
- **Dependabot** for pip, pub, GitHub Actions and Docker (`.github/dependabot.yml`)
- **Trivy** scan of the API image
- **Secret scanning + push protection** (GitHub repo settings)

---

## 11.8 Disaster recovery

**Do and document** in `docs/operations/`:
1. **Postgres point-in-time restore drill:** restore staging to "10 minutes ago" into a new server. Time it and write the steps down.
2. **Storage:** blob versioning + soft delete on, geo-redundant replication in production.
3. **Runbooks** (step-by-step, copy-pasteable):
   - "Revoke a patch everywhere right now"
   - "Signing key compromised"
   - "API down: what devices do and how to recover"
   - "Roll back a bad backend deployment" (Container Apps: activate the previous revision)

---

## 11.9 Cost model

**Do:** a spreadsheet using this formula: Front Door egress GB × price + requests + Blob + Postgres + Container Apps + Event Hubs + App Insights + Key Vault (+ Redis). Fill it with real numbers from the Azure pricing calculator for your region. Patch size is the biggest cost driver, so show the cost of a 1 MB vs 5 MB patch to 1M users.

---

## Phase 11 is done when

- [ ] Load targets met in staging with headroom. Report written
- [ ] Every chaos case recovers to known-good or store version
- [ ] Threat model and runbooks written. Restore drill done and timed
- [ ] 🎉 **Milestone G**: you can say "ready for 1M DAU" with evidence
