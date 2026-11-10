# Rollouts

How to move a patch from testers to all users safely, and how to stop it. Background:
[concepts.md](concepts.md#staged-rollout). Commands: [cli-reference.md](cli-reference.md).

> **What exists today.** Channels, percentage rollouts, rollback, revoke, boot success/failure
> counters, and server-side promotion checks for `production`. **Not implemented:** automatic pausing, alerts, dashboards,
> targeting beyond channel/release/arch, scheduled rollouts. Every step below is manual.

## Channels

Every new application gets `dev`, `staging` and `production`. Add more (for example `qa`) with the
API. There is no CLI command or admin-page button for this yet:

```bash
curl -X POST -H "X-API-Key: $OTA_API_KEY" -F name=qa "$OTA_API_URL/v1/admin/apps/my-app/channels"
# ["dev","staging","production","qa"]
```

Channels cannot be renamed or deleted through the API.

A device's channel is chosen **by the app**, not by the server:

| How | Example |
|---|---|
| Build default | `--dart-define=OTA_CHANNEL=staging` (helper in [flutter-integration.md](flutter-integration.md)); otherwise `production` |
| At runtime | `OtaClient.setChannel('qa')`, e.g. from a hidden tester menu. Saved on the device; `null` returns to the build default |

A suggested setup:

| Channel | Who | Purpose |
|---|---|---|
| `dev` | Developers' own devices | Try a patch at all |
| `qa` (optional) | QA team | Test plan |
| `staging` | Internal testers on tester builds | Real use before users; `ota patch promote` starts here |
| `production` | Everyone else | Percentage rollout |

## How a percentage rollout works

Each (patch, channel) pair has a rollout percentage. A device is included when its bucket
(0–9999, from an HMAC of the application id, installation id and **patch id**) is below
percentage × 100.

- Raising the percentage of the **same** patch only adds devices; nobody already included drops
  out.
- Lowering it removes devices from the offer, but devices that already **installed** the patch
  keep running it. To take a patch away from devices, use rollback or revoke.
- A different patch uses different buckets.
- Setting 0% stops new devices from getting it; devices that have it keep it.

## Canary rollout: 1% → 5% → 25% → 50% → 100%

Example: patch `#4` of `my-app` release `1.0.0+1`, id `<id>`.

**1. Staging first.**

```bash
ota patch android my-app --channel staging --note "fix checkout total"
```

Testers restart the app twice (download, then run). Check the counters:

```bash
ota patch show <id>          # "event_counts": {"patch_boot_succeeded": 6, ...}
```

**2. Canary: 1% of production.** The server refuses to raise a patch on `production` unless it
has been live on another channel (such as `staging`) and has **no** reported boot failures. This
applies to `promote`, `publish`, `rollout`, the admin page and direct API calls. To skip the checks
on purpose, add `--force --reason "…"`; the server logs the reason:

```bash
ota patch promote <id> --percent 1
```

**3. Widen step by step.** Between steps, wait long enough for devices to check, download, restart
and confirm (with the default client helper: at least one app start after the download), then
read the counters again:

```bash
ota patch rollout <id> --channel production --percent 5
ota patch rollout <id> --channel production --percent 25
ota patch rollout <id> --channel production --percent 50
ota patch rollout <id> --channel production --percent 100
```

Before each step, check:

| Signal | Where | Go / stop |
|---|---|---|
| `patch_boot_failed`, `patch_auto_rollback` | `ota patch show <id>` → `event_counts`, or the admin page (**Boot ok / failed**, "Crashing" warning) | Any increase → stop and investigate |
| `patch_hash_failed`, `patch_signature_failed` | same | Should be 0. Non-zero → file or key problem ([troubleshooting.md](troubleshooting.md)) |
| `patch_boot_succeeded` | same | Should grow with the rollout |
| Devices per patch number | `GET /v1/admin/apps/<slug>/devices/summary` or the admin page **Devices** table | Shows adoption |
| Your own crash reporting and business metrics | your tools | Punit only sees boot success/failure |

The counters are **totals per patch** across all channels, not per percentage step.

**4. Stop or undo.** Choose the smallest action that solves the problem:

| Situation | Action |
|---|---|
| Want to pause new installs, keep current ones | `ota patch rollout <id> --channel production --percent 0` |
| The patch is bad; devices should leave it | `ota patch rollback <id>` (can be published again later) |
| The patch must never run again | `ota patch revoke <id> --yes` |

The admin page offers the same: **Promote to production**, **Set %**, **Publish**, **Roll back**,
**Revoke**. Its promote button shows the staging results. When the server refuses (untested
patch, or boot failures), the page shows the reason and asks you to type why before it overrides
the checks. Lowering a percentage, rolling back and revoking are never blocked. Which channels are
protected is set with `OTA_PROTECTED_CHANNELS` (default `production`,
[configuration.md](configuration.md)). Before this fix only the CLI checked:
[KI-4](known-issues.md#ki-4-promote-safety-checks-are-enforced-only-by-the-cli).

## Rollback in detail

`ota patch rollback <id>`:

1. The patch becomes `rolled_back` and is no longer offered on any channel.
2. On their next check, devices running it receive `rolled_back_patch_numbers` with its number,
   and `rollback_to_patch_number` = the newest other patch they are eligible for, or `0` (store
   code).
3. They switch on their **next app start**.

To publish it again later: `ota patch publish <id> --channel staging --percent 100`.

## Revocation in detail

`ota patch revoke <id> --yes` makes the patch `revoked` for good. It appears in
`revoked_patch_numbers` in every check response for that release, and clients drop it even if it
is already downloaded or staged. Revoke a patch that is crashing, or that you did not publish.

## How fast do changes reach devices?

Punit cannot push to devices. A device learns about a new patch, a rollback or a revocation only
when the app calls `checkForUpdate()` (with the helper: once per app start), and the change runs on
the start after that. Devices that are offline or never opened see nothing. Plan rollouts and
emergency responses with that delay in mind.

## Device targeting

Only application, release, platform, architecture, channel and percentage. There is no targeting
by device model, OS version, country or user. To reach a specific group, give them a dedicated
channel (build default or `setChannel`).

## Testing rollout percentages locally

```bash
python scripts/simulate_fleet.py --app punit-demo --release 1.0.0+1 --channel production --devices 1000
```

It registers 1000 fake installations (stable ids, so re-runs reuse them) and counts which patch
each is offered. See [installation.md](installation.md#9-try-more-cases-optional).
