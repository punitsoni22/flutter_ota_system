# Privacy and data handling

What the Flutter OTA System client SDK (`flutter_ota_system`) and the self-hosted server actually
store and send, traced from the source code (the original `OtaClient` runtime of v0.1.0-alpha.1, and the bytecode
runtime `FlutterOta` since v0.2.0-alpha). Use it when you write your app's
privacy policy, Google Play **Data safety** answers or other disclosures.

> [!IMPORTANT]
> This documentation is provided for technical guidance and is not legal advice. Platform
> policies can change. Developers are responsible for independently reviewing the policies
> applicable to their applications and distribution channels.
>
> External sources were checked on **2026-11-12**.

## The self-hosted model

Flutter OTA System has no hosted service: the SDK talks **only** to the server URL you configure
(`OtaConfig.serverUrl`) and to the download URLs that server hands out. The **operator** (you, or
whoever runs the server for your app) controls the backend, the PostgreSQL database, the artifact
storage, server and proxy logs, their retention, who can access them, and the privacy policy of
the deployment.

Self-hosting keeps the data with you; it does **not** by itself make a deployment private or
compliant. Hosting providers, CDNs, object storage and reverse proxies you choose may keep their
own logs.

## What the SDK sends

Exactly these requests leave the device (source:
[`ota_client.dart`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/lib/src/ota_client.dart)):

| Request | When | Data sent |
|---|---|---|
| `POST /v1/devices/register` | First check, and whenever the server answers `401` | JSON body: `app` (app slug), `installation_id`, `platform` (`android`), `arch` (CPU ABI, e.g. `arm64-v8a`), `release_version` (e.g. `1.0.0+1`), `channel` |
| `GET /v1/updates/check` | Each `checkForUpdate()` (the server's interval is respected unless forced) | Query: `platform`, `arch`, `release_version`, `channel`, `current_patch_number`, `supported_formats`, and up to 20 `failed_patch_ids`. Header: `Authorization: Bearer <device token>` |
| `POST /v1/events/batch` | During checks and after `markBootSuccessful()` | JSON body: up to 100 events, each `{type, patch_id}`. Types: `patch_downloaded`, `patch_hash_failed`, `patch_signature_failed`, `patch_staged`, `patch_boot_succeeded`, `patch_boot_failed`, `patch_auto_rollback`. Header: device token |
| `GET <download_url>` | When a patch is offered | No body and no token: a plain download from your file server, CDN or bucket |

Every request also carries what any HTTPS client sends: the device's **IP address** (as seen by
the server or proxy) and a `User-Agent` header (the default `dart:io` value, e.g.
`Dart/<version> (dart:io)`).

**Bytecode runtime (`FlutterOta`).** It registers with `application_id` (UUID), `installation_id`,
`platform`, `arch`, `release_version` and `channel`, and its update check adds
`current_patch_number`, `supported_formats=dbc-v1` and the ids of patches that failed on the
device. It keeps its state in the app's private storage: `device.json` (installation id and access
token), `state.json`, the patch files (`active.otp`, `previous.otp`, `pending.otp`),
`attempt.json` and `session.json`.

**Not sent by the SDK:** device model, OS version, Android ID, advertising ID, phone number,
location, user account or any personal content, crash reports or stack traces. Error messages
(`UpdateResult.message`) stay on the device. The SDK has no analytics or third-party services.

## Field inventory

| Field | Purpose | Origin | Sent | Stored on the server | Retention | Linkable? |
|---|---|---|---|---|---|---|
| `installation_id` | Identifies one installation, so the server can issue a token, count devices and place the installation in percentage rollouts | 16 random bytes (hex), created on first launch (`Random.secure`) | Register body; inside the device token | `devices.installation_id` | Until the operator deletes the row (no automatic deletion) | Pseudonymous id of one installation. Not derived from hardware or the user. Could be linked to a person if combined with other data (e.g. IP address in logs, or your app's own data) |
| Device token | Authorises check and event calls for one device of one app | Issued by the server (HS256 JWT; claims: device id, application id, installation id, type, issue and expiry time; default lifetime 30 days) | `Authorization` header | **Not stored** (verified statelessly) | On the device until replaced | Contains the installation id |
| Device id (`devices.id`) | Server row key | Server (UUID) | Inside the token | `devices.id` | As the row | Linked to the installation |
| `platform`, `arch` | Offer the right patch for the platform and CPU ABI | Device | Register, check | `devices.platform`, `devices.arch` | As the row | Low (non-unique) |
| `release_version` | Match the installed store build to a server release | Your `OtaConfig.releaseVersion` | Register, check | `devices.release_version` | As the row | Low |
| `channel` | Pick patches for `production`, `staging`, … | `OtaConfig.channel` or `setChannel()` | Register, check | `devices.channel` | As the row | Low |
| `current_patch_number` | Avoid re-offering the running patch; rollback decisions | Client state | Check | `devices.current_patch_number` | As the row | Low |
| `supported_formats` | Offer only patches the runtime can run | Runtime | Check | Not stored | — | No |
| `failed_patch_ids` | Skip patches that crashed on this device | Client state | Check | Not stored | — | Low |
| Event `{type, patch_id}` | Boot success/failure counts that drive rollout safety checks | Client | Events batch | **Only aggregated** counts per patch and event type (`patch_event_counts`); not linked to a device | Kept with the patch (no automatic deletion) | No (after aggregation) |
| Registration time, last check | Device counts; `last_seen` updated at most hourly, or when release/channel/patch changes | Server clock | — | `devices.created_at`, `devices.last_seen` | As the row | Linked to the installation |
| Rollout bucket | Stable percentage rollouts | Server: HMAC of application id, installation id and patch id | — | Not stored (computed per check) | — | — |
| IP address, `User-Agent` | Network delivery | Network / `dart:io` | Every request | **Not in the database.** In access logs; see below | Log rotation | Can identify a network and, with timing, an installation |

There is no endpoint to delete a single device. The admin API and admin page show only
aggregated counts (platform, release, channel, patch). Operators who need per-installation
deletion must do it in the database.

## Server-side logs (infrastructure, not the SDK)

| Component (as shipped in this repository) | What it logs by default | Where it goes |
|---|---|---|
| API (uvicorn) | Access log: client IP (the forwarded IP when the proxy is trusted), method, path **with query string** (`release_version`, `channel`, `failed_patch_ids`, …), status. The device token is a header and is not logged | Container stdout → Docker `json-file` logs, rotated at 10 MB × 3 files (`docker-compose.yml`) or × 5 (`deploy/docker-compose.prod.yml`) |
| File server (nginx) | nginx's default access log: client IP, time, request line (patch hash path), status, size, referrer, `User-Agent` | Container logs, same rotation |
| Caddy (TLS front in `deploy/`) | No access log (no `log` directive configured) | — |
| S3-compatible storage (Supabase, R2, AWS) | Whatever the provider logs for public-bucket downloads | The provider's systems |
| Backups (`deploy/backup.sh`) | Copy the database (including `devices`) and files daily; kept 14 days; **not encrypted by the script** | `./backups` on the server |

Your own proxies, load balancers, CDNs and hosting platforms can log more. Review them.

## What stays on the device

All in the app's private storage (application support / files directory):

- `ota/state.json`: installation id, device token, release version and server release id, active,
  staged and last-good patch records (id, number, hashes, signature, download URL), failed patch
  ids, highest accepted patch number, time of the last check, chosen channel, and up to 100
  pending events.
- `ota/patches/<patch id>/`: staged and active patch files.
- Android code patches only: `ota_aot/boot.json` (next and last-good patch: id, number, file path,
  SHA-256, size, and an install stamp made of the app's `versionName`, `versionCode` and
  `lastUpdateTime`) and `ota_aot/native.json` (boot attempt, up to 50 failed patch ids, and
  verification stamps). A temporary copy of the store `libapp.so` is written to the cache
  directory while a patch is staged, then deleted.

These files are not encrypted by the SDK and the token is not in a hardware-backed keystore. If
your app allows Android backup, they can be backed up and restored with the rest of the app's
files, which may carry the installation id and token to a restored installation.

## Your responsibilities as the app developer

- **Google Play Data safety:** you must declare the data collected by your app, **including by
  SDKs** it uses ([Data safety](https://support.google.com/googleplay/android-developer/answer/10787469)).
  Use the inventory above to decide which data types apply to your deployment (for example an
  app-scoped identifier, app version and diagnostics-style boot events, and IP addresses in your
  server logs). This page does not give a pre-filled answer: the result depends on your server,
  logs and other systems.
- **Privacy policy:** describe the OTA data flow, the operator, retention and how users can ask
  for deletion, as your jurisdiction requires.
- **Third-party SDK requirements:** Google Play also holds apps responsible for the SDKs they
  include ([SDK requirements](https://support.google.com/googleplay/android-developer/answer/13323374)).
- **Operator controls:** decide log retention, restrict database and log access, encrypt backups,
  and define how device rows are deleted.

## Apple platforms

The package declares **Android only**; there is no iOS implementation and no Apple privacy
manifest. A privacy manifest is not added, because it would describe an implementation that does
not exist. Any future iOS support must review Apple's
[privacy manifest](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
and [third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
for that actual implementation. See [policy/apple-app-store.md](policy/apple-app-store.md).

## Related

- [security.md](security.md): security model, limitations, signing keys and the trust model
- [policy/google-play.md](policy/google-play.md): Google Play policy considerations
