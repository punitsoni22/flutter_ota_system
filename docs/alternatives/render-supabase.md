# Render + Supabase hosting (not recommended, unsupported)

> [!WARNING]
> **This is not the recommended way to run Punit.**
>
> - Punit is **self-hosted**: the official installation method is Docker on infrastructure you
>   control (see [setup-guide.md](../setup-guide.md) and [deploy.md](../deploy.md)).
> - This page and [`render.yaml`](../../render.yaml) are **kept for reference only**. They were
>   used for early internal testing on free tiers. They are **not maintained** and have **not been
>   re-tested** for v0.1.0-alpha.
> - Free tiers sleep, pause and change their limits. Do not use them for real users.
> - Render, Supabase and Cloudflare are third-party services with their own terms. Punit is not
>   affiliated with them.
>
> After you finish, continue with Parts B and C of [setup-guide.md](../setup-guide.md). Use your
> Render address wherever the guide says `<server>`.

## Free cloud hosting (testing only)

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
