# Setup guide: free test hosting, then any Flutter app

> Day-to-day app work (set up an app, store releases, patches, rollout): see **[app-guide.md](app-guide.md)**.

Two parts:

- **Part A**: put the OTA server on free cloud services (Supabase + Render), so phones anywhere can reach it.
- **Part B**: add OTA to a Flutter app and test Dart code patches, staging → production, and rollback.

For real users later, move to proper hosting ([deploy.md](deploy.md), or paid tiers of the same
services). Parts B and C stay the same; only the server address and the key change.

---

## Part A: free cloud hosting (testing only)

Three free services, no server to look after:

| Piece | Service | Free tier |
|---|---|---|
| Database | **Supabase** Postgres | 500 MB, no card |
| Patch files | **Supabase Storage** (or **Cloudflare R2**) | 1 GB and 5 GB downloads/month (R2: 10 GB, free downloads) |
| API server | **Render** web service (Docker) | 512 MB RAM, no card; sleeps after 15 min idle |

What runs where:

```
phones ──► Render (API: checks, signing, admin page) ──► Supabase Postgres
   │
   └──── download patch files ──► Supabase Storage public bucket "ota-public"
         store builds (private) ──► bucket "ota-private" (admin API only)
```

Free-tier catches, all fine for testing:

- **Render sleeps** after 15 minutes without requests, and the first request then takes ~1 minute.
  Step 5 keeps it awake with a free pinger.
- **Supabase pauses** a free project after 7 days without activity. The pinger counts as activity.

You need: a GitHub account with this repo pushed (Render deploys from GitHub), plus free accounts at
https://supabase.com and https://render.com (sign in with GitHub).

### 1. Supabase: database

1. https://supabase.com/dashboard → **New project**:
   - name `flutter-ota`;
   - a strong **database password** (save it);
   - region near your users (e.g. **Mumbai**).
2. When it's ready: the **Connect** button (top) → **Session pooler** → copy the URI:
   ```
   postgresql://postgres.<ref>:[YOUR-PASSWORD]@aws-0-ap-south-1.pooler.supabase.com:5432/postgres
   ```
   Put your password in place of `[YOUR-PASSWORD]`. This is `OTA_DATABASE_URL`.

   Use the **Session pooler**, not "Direct connection": Render can't reach Supabase's direct address.

The server creates its tables itself on first start.

### 2. Supabase: file storage

1. **Storage** → **New bucket** → name `ota-public`, **Public bucket: ON** → Create.
2. **New bucket** → name `ota-private`, **Public bucket: OFF** → Create.
3. **Project Settings → Storage → S3 Connection**: copy **Endpoint**
   (`https://<ref>.supabase.co/storage/v1/s3`) and **Region** (e.g. `eu-west-1`).
4. Storage keys, without creating anything: the server signs in with the project's own keys
   (**Project Settings → API Keys**):

   | Setting | Value |
   |---|---|
   | `OTA_S3_ACCESS_KEY_ID` | the project ref (`<ref>`) |
   | `OTA_S3_SECRET_ACCESS_KEY` | the **anon** key |
   | `OTA_S3_SESSION_TOKEN` | the **service_role** key (secret) |

   (Dashboard **S3 Access Keys** work too: key id + secret, and leave the session token empty.)
5. Your public file address (`OTA_CDN_BASE_URL`) is:
   ```
   https://<ref>.supabase.co/storage/v1/object/public/ota-public
   ```
   `<ref>` is the project id in your Supabase URL.

<details>
<summary>Prefer Cloudflare R2 for files? (more space, free downloads; Cloudflare may ask for a card)</summary>

1. Cloudflare dashboard → **R2** → create buckets `ota-public` and `ota-private`.
2. `ota-public` → **Settings → Public access → R2.dev subdomain → Allow**. Copy the URL
   (`https://pub-<id>.r2.dev`): that is `OTA_CDN_BASE_URL`.
3. R2 → **Manage API tokens → Create API token**:
   - permission **Object Read & Write**, limited to the two buckets;
   - copy the **Access Key ID** and **Secret Access Key**.
4. Endpoint: `https://<account-id>.r2.cloudflarestorage.com`. Region: `auto`.

Use these values in step 4 instead of Supabase's. The database stays on Supabase.
</details>

### 3. Create the signing key (once, on your Mac)

```bash
cd ~/Desktop/flutter_ota_system/backend
OTA_SIGNING_KEY_ID=cloud-1 ../.venv/bin/python -m app.keygen --pem
```

It prints two things:

- **`OTA_SIGNING_KEY_PEM`**: one long line starting with `-----BEGIN PRIVATE KEY-----`. It is a
  secret: save it in a password manager.
- **`OTA_PUBLIC_KEY`** for the apps, e.g. `cloud-1:BIi7De…`.

Apps trust only this key. Losing it means new store builds for every app, so keep it safe.

### 4. Render: API server

1. Make sure this repo, including `render.yaml`, is pushed to GitHub.
2. https://dashboard.render.com → **New → Blueprint** → connect GitHub → pick the `flutter_ota_system` repo.
   Render reads `render.yaml` and asks for these values:

   | Key | Value |
   |---|---|
   | `OTA_DATABASE_URL` | Session pooler URI from step 1 |
   | `OTA_SIGNING_KEY_PEM` | the one-line key from step 3 |
   | `OTA_CDN_BASE_URL` | public file address from step 2 |
   | `OTA_S3_ENDPOINT_URL` | Endpoint from step 2 |
   | `OTA_S3_REGION` | Region from step 2 |
   | `OTA_S3_ACCESS_KEY_ID` | project ref from step 2 |
   | `OTA_S3_SECRET_ACCESS_KEY` | anon key from step 2 |
| `OTA_S3_SESSION_TOKEN` | service_role key from step 2 |

3. **Apply**. The first build takes ~5 minutes. Your server address is shown at the top, e.g.
   `https://<your-service>.onrender.com`.
4. Check it: open `https://<your-service>.onrender.com/health/ready` → `{"status":"ok"}`.
   If not, the **Logs** tab names the problem. The server refuses to start with a missing or unsafe
   setting, and says which one.
5. Your **admin key**: service → **Environment** → `OTA_ADMIN_API_KEY` (Render generated it).

Later code changes deploy automatically when you push to GitHub.

### 5. Keep it awake (free pinger)

https://uptimerobot.com (free) → **New monitor**:

- type **HTTP(s)**;
- URL `https://<your-service>.onrender.com/health/ready`;
- interval **5 minutes**.

This keeps Render from sleeping and Supabase from pausing, and emails you if the server goes down.

### 6. Connect the CLI and the admin page

On your Mac (add these to `~/.zshrc` to keep them):

```bash
alias ota="$HOME/Desktop/flutter_ota_system/.venv/bin/python $HOME/Desktop/flutter_ota_system/cli/ota.py"
export OTA_API_URL=https://<your-service>.onrender.com
export OTA_API_KEY=<OTA_ADMIN_API_KEY from Render>
ota app list            # [] = connected
```

Admin page: `https://<your-service>.onrender.com/admin`, with the same key.

From here on, **"server"** means `https://<your-service>.onrender.com`.

---

## Part B: set up an app

The example uses an app called `my-app`.

### 1. Add the package

`pubspec.yaml`:

```yaml
dependencies:
  package_info_plus: any         # if the app doesn't have it already
  ota_client:
    git:
      url: https://github.com/punitsoni22/flutter_ota_system.git
      path: packages/ota_client
```

The git URL works for anyone with access to the repo. On your Mac alone, a path works too:
`path: ../flutter_ota_system/packages/ota_client`. Then run `flutter pub get`.

### 2. Start OTA in the app

Add a small updater file to the app, e.g. `lib/ota_updater.dart`, based on the snippet in
[code-push.md](code-push.md) (step 2), and set the app slug:

```dart
static const _appSlug = 'my-app';
```

In `main.dart`, start it **after** the first frame. It never delays startup:

```dart
runApp(const MyApp());
WidgetsBinding.instance.addPostFrameCallback((_) => OtaUpdater.start());
```

That is all the code. No `MainActivity` changes. The app needs the `INTERNET` permission, which
almost every app already has.

### 3. Register the app on the server (once)

```bash
ota app create my-app "My App" --distribution public_store
ota app approve-policy my-app --reason "Dart-only code patches for testing"
ota key show          # copy key_id and uncompressed_point_base64
```

The public key for the app is `<key_id>:<uncompressed_point_base64>`, e.g. `dev-1:BIXZd…`.

### 4. Choose the build settings

Every build of the app gets these, plus the app's own `--dart-define`s:

```bash
--dart-define=OTA_SERVER_URL=https://<server>
--dart-define=OTA_PUBLIC_KEY=<key_id>:<point>
--dart-define=OTA_CHANNEL=staging          # tester build; production builds leave this out
```

For an app that also talks to its own staging API, the full set is:

```bash
--dart-define=API_BASE_URL=https://api.example.com/ \
--dart-define=OTA_SERVER_URL=https://<server> \
--dart-define=OTA_PUBLIC_KEY=<key_id>:<point> \
--dart-define=OTA_CHANNEL=staging
```

### 5. Build and register the store build (the "release")

In the app's folder. Everything after `--` goes to `flutter build`.

```bash
cd ~/path/to/my_app
ota release android my-app --kind apk -- <the dart-defines from step 4>
```

It builds the APK, registers the version from `pubspec.yaml` (e.g. `1.0.0+1`), and uploads its
compiled code. It ends with the APK's path.

- `--kind apk`: a file you install directly (testing). For Play, leave it out to get an AAB and
  upload **exactly that file** to Play Console.
- **Already registered this version?** (e.g. `1.0.0+1` from a local test.) Delete the old
  one first: `ota release delete my-app --version 1.0.0+1`. A rolled-back or draft patch is fine;
  a published one must be rolled back first.

### 6. Install it on test phones

- **Phone with USB** (Developer options → USB debugging on):
  `adb install -r build/app/outputs/flutter-apk/app-release.apk`
- **Phones elsewhere:** send them the APK (Drive, WhatsApp, Firebase App Distribution). They open
  it and allow "install unknown apps".
- **Emulator:** `adb install -r build/app/outputs/flutter-apk/app-release.apk`

Open the app once. It contacts the server: the admin page's **Devices** table lists it within a
few seconds.

> **Never** `flutter run` or rebuild and reinstall between patches. A new APK is a new store
> build, and old patches don't fit it. To start over, repeat steps 5–6.

---

## Part C: test it

### Send a code change

```bash
# 1. change any Dart code, e.g. a text
# 2. in the app folder:
ota patch android my-app --channel staging --note "new welcome text"
```

It takes about 3–5 minutes (it builds the app again) and ends with
`Patch #1 for 1.0.0+1: published to staging at 100%`.

It **refuses** with "needs a store release" if you changed anything other than Dart: images,
fonts, `.env`, plugins, Kotlin or Java, the Android manifest, or the Flutter version.

### See it on the phone: two restarts

1. **Close the app fully** (recent apps → swipe it away), open it, and wait **10 seconds**. It
   downloads the patch; the screen doesn't change yet.
2. **Close it fully again, and open it.** The change is there.

On the admin page the patch shows **Boot ok: 1** a few seconds later.

### Staging → production

The phones built with `OTA_CHANNEL=staging` got it. Production phones haven't yet.

```bash
ota patch list my-app --platform android --release 1.0.0+1     # find the patch id
ota patch promote <patch_id> --percent 10                      # 10% of production phones
ota patch rollout <patch_id> --channel production --percent 100
```

Or use the admin page: **Promote to production**, then **Set %**. Promotion is refused if any
staging phone reported a boot failure.

### Roll back

Admin page → **Roll back** (or `ota patch rollback <patch_id>`). Then on the phone: open it (it
learns about the rollback), close it, open it again: the previous code is back.

The app checks the server **on every start**, and every 30 minutes while it stays open.

### Crash protection

To test it, put a crash in startup code, e.g. at the end of `main()`:

```dart
WidgetsBinding.instance.addPostFrameCallback((_) => exit(1));   // import 'dart:io';
```

1. Send it with `ota patch android my-app --channel staging`.
2. Do the two restarts: the app closes right away.
3. Open it once more: it starts on the previous good code.

The admin page shows that patch as **Crashing** (Boot failed: 1), and `promote` refuses it.
Remove the crash line afterwards.

### Ship one fix while main has other unfinished work

A patch is always the whole app as the code is now. Build it from a branch with only the fix:

```bash
git switch -c hotfix-1 <tag or commit of the store build>
git cherry-pick <the fix commit>
ota patch android my-app --channel staging
git switch main
```

Tag every store build when you run `ota release android` (e.g. `git tag v1.0.0+1`), so this is easy.

---

## Quick reference

| Task | Command |
|---|---|
| New app | `ota app create <slug> "<Name>" --distribution public_store` + `ota app approve-policy <slug> --reason "..."` |
| App's public key | `ota key show` |
| New store build | `ota release android <slug> [--kind apk] -- <dart-defines>` |
| Remove a test release | `ota release delete <slug> --version <x.y.z+n>` |
| Code patch | `ota patch android <slug> --channel staging` |
| List patches | `ota patch list <slug> --platform android --release <x.y.z+n>` |
| To production | `ota patch promote <id> --percent 10` |
| Change % | `ota patch rollout <id> --channel production --percent 50` |
| Undo | `ota patch rollback <id>` (or `revoke <id> --yes` for never again) |

## Problems

| Symptom | Fix |
|---|---|
| `zsh: command not found: ota` | Run the `alias ota=...` line (Part A, step 6) |
| `error 401` from `ota` | `OTA_API_KEY` is not set, or isn't Render's `OTA_ADMIN_API_KEY` |
| `policy_review_required` | `ota app approve-policy <slug> --reason "..."` |
| `Release ... already exists` | `ota release delete <slug> --version <v>`, or raise the build number |
| `assets changed` / `needs a store release` | The change isn't Dart-only: make a new store build (Part B, step 5) |
| `Flutter changed` | Use the Flutter version the release was built with |
| Phone never gets the patch | Was the app built with `OTA_SERVER_URL` and `OTA_PUBLIC_KEY`? Is the server awake (`/health/ready`)? Is the phone on the patch's channel? Is it a **release** build (debug builds ignore patches)? |
| Patch shows but disappears after a restart | It crashed or was closed within 5 seconds of opening; check Boot failed on the admin page |
| Admin page empty | Enter the admin key and click Connect |
| First request very slow, or a check fails | Render was asleep; set up the pinger (Part A, step 5) |
| Server won't start (Render logs: `Unsafe production settings`) | Fix the setting it names in Render → Environment |
| `ota release android` upload fails | Check the S3 keys and bucket names; `ota-private` must exist |
