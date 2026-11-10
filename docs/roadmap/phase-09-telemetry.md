# Phase 9 — Telemetry and observability (3–5 pw) → Milestone E

> **Roadmap status: 🟡 partial.**
> - ✅ `POST /v1/events/batch` (returns 202), client-side events, per-patch counters in PostgreSQL
>   shown on `/admin`. `ota patch promote` refuses a patch with boot failures unless `--force`.
> - 🔭 Not built: Event Hubs (9.4), a separate worker (9.5; counters are written directly),
>   OpenTelemetry / Application Insights (9.6), dashboards (9.7), automatic rollout pausing (9.8)
>   and alerts (9.9).

**Goal:** see how every patch behaves in the field, and **automatically pause** a rollout when a patch is bad.

**New concepts:** event streaming (Event Hubs), consumers and checkpoints, OpenTelemetry, dashboards, alert rules.

> **Scope note (ADR-0011):** dashboards and automatic pausing are out of scope. **Do only 9.1, 9.2, 9.3 and 9.5.** For 9.5, the worker only needs to keep per-patch counters (`patch_boot_succeeded`, `patch_boot_failed`, `patch_auto_rollback`, hash/signature failures). Read these with the CLI (`ota patch stats <patch_id>`) before each rollout step up. Skip 9.4 if you don't need local Event Hubs, and skip 9.6–9.9.

Branch: `git switch -c phase-9-telemetry`.

---

## 9.1 The event vocabulary

**Do:** add the event type enum to `ota_protocol` (Dart) and the backend (Python), with exactly these names:

```
update_check_started / _succeeded / _failed
patch_offered
patch_download_started / _succeeded / _failed
patch_hash_verified / _failed
patch_signature_verified / _failed
patch_staged / patch_stage_failed
patch_activation_started / _succeeded / _failed
patch_boot_started / patch_boot_confirmed
patch_auto_rollback
patch_revoked_seen
```

Each event carries: `event_id` (UUID, for de-duplication), `type`, `occurred_at`, `release_id`, `patch_id`, `patch_number`, `platform`, `arch`, `runtime_version`, `channel`, `rollout_id`, `rollout_bucket`, `error_code`, `duration_ms`, `payload_size`. **No personal data** (no names, emails or IP addresses in the event body).

---

## 9.2 `POST /v1/events/batch`

**Why:** 1M devices × 5 events = 5M events per patch. Writing each to Postgres would overload it. Instead the API accepts, validates, and forwards to a queue built for this.

**Do:**
1. Validate: max 100 events per batch, max 64 KB body, known types only, `occurred_at` not more than 7 days old or 1 hour in the future.
2. Add `device_id` and `application_id` from the JWT (never trust the body for identity).
3. Send to an `EventSink` interface, then return **202** `{"accepted": true}` immediately.

`EventSink` implementations:
- `LogEventSink`: writes events to logs. Use it for local development first.
- `EventHubsSink`: `azure.eventhub.aio.EventHubProducerClient`, sending batches with `create_batch()` / `send_batch()`. Partition key = `application_id`.

If the sink is down, return **503** so the client retries later. Never block the app.

---

## 9.3 Client-side telemetry

**Do:** in `ota_client`:
- Append events to a local file queue, capped at 500 events (drop the oldest).
- Flush every 60 s or when 20 events are queued, and at app pause.
- On 202, delete the sent events. On failure, keep them and back off.
- Never let telemetry errors affect the app or the update flow.

---

## 9.4 Local Event Hubs (optional)

**Do:** Microsoft publishes an **Event Hubs emulator** container (`mcr.microsoft.com/azure-messaging/eventhubs-emulator`). It needs a small JSON config and uses Azurite. Add it to `docker-compose.yml` under a profile (`profiles: ["telemetry"]`) so it only starts when you ask: `docker compose --profile telemetry up`.

If the emulator is too fiddly, keep `LogEventSink` locally and test `EventHubsSink` against a real dev Event Hub after Phase 10.

---

## 9.5 The telemetry worker

**Do:** `workers/telemetry/`, a separate Python process with its own Dockerfile:
1. Read with `EventHubConsumerClient` + `BlobCheckpointStore` (package `azure-eventhub-checkpointstoreblob-aio`). The checkpoint store remembers where it stopped, so a restart doesn't reprocess everything.
2. Every minute, aggregate counts per `(patch_id, rollout_id, cohort, event_type)` into a Postgres table `rollout_health_minutely`. Cohort is `patched` or `control`, based on the bucket.
3. De-duplicate by `event_id` within a window, since devices may resend.
4. Send summary metrics to Application Insights (9.6).

**Check:** send 1,000 fake events and confirm the aggregates add up.

---

## 9.6 OpenTelemetry + Application Insights

**Do:**
1. Add `azure-monitor-opentelemetry` to the backend and worker.
2. At startup: `configure_azure_monitor(connection_string=settings.appinsights_connection_string)` when the setting is present. Locally it stays off.
3. You get request traces, latency, and dependency calls (Postgres, Blob) automatically. Add custom metrics: `ota.check.decisions{reason=...}` and `ota.events.accepted`.

---

## 9.7 Dashboards

**Do:** build one Azure Monitor **Workbook** (or Grafana) with:
- Check success rate and p95 latency
- Download success, hash failures, signature failures
- Activation success, boot failures, auto-rollbacks
- **Patched vs control** crash / startup-failure rate for the active rollout
- API 5xx rate

---

## 9.8 Rollout health gates (automatic pause)

**Why:** a bad patch at 10% of 1M users hits 100,000 people. A machine reacts in minutes. A human might not notice for hours.

**Do:** a job in the worker, every minute, for each running rollout. Planned thresholds:

| Metric | Pause if | Notes |
|---|---|---|
| Download success | < 98.5% | |
| Hash failure | ≥ 0.1% | |
| Signature failure | ≥ 0.05% | Any sustained occurrence is suspicious |
| Activation success | < 98.5% | |
| Patch-induced boot failure | ≥ 0.5% | |
| Crash rate vs control | > 10% relative increase | |

Rules:
- Only judge when there are **enough events** (for example ≥ 500 activations). Small numbers are noise.
- Action = set the rollout to `paused` with `deployment_events` type `auto_pause` and actor `system`. **Do not auto-revoke.** A human confirms revoke.
- Promotion (for example 10% → 25%) is only allowed when the gates are green **and** the minimum volume is reached.

**Check:** 🎉 **Milestone E**: simulate a patch whose devices report 2% boot failures. The rollout pauses within 2 minutes and an alert fires.

---

## 9.9 Alerts

**Do:** Azure Monitor alert rules → an Action Group (email for now) for: auto-pause happened, API 5xx > 0.5% for 5 minutes, check p95 > 1 s for 10 minutes, worker lag > 5 minutes.

---

## Phase 9 is done when

- [ ] `/events/batch` never touches Postgres and returns 202
- [ ] Worker aggregates are correct and survive restarts (checkpoints)
- [ ] A dashboard shows patched vs control
- [ ] The auto-pause demo works
