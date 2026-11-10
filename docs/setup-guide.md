# Setup guide: run your own Punit server, then add OTA to a Flutter app

> Day-to-day app work (set up an app, store releases, patches, rollout): see
> **[app-guide.md](app-guide.md)**.

Punit is **self-hosted**. You run the server on a machine you control, and **Docker is the
official installation method**. There is no hosted Punit service.

This guide has three parts:

- **Part A**: start your own Punit server with Docker and connect the `ota` CLI.
- **Part B**: add OTA to a Flutter app.
- **Part C**: test Dart code patches, staging → production, rollback and crash protection.

> [!NOTE]
> **Status (v0.1.0-alpha).** The **local** Docker stack (Part A, option 1) is what the maintainers
> test, with `scripts/verify_demo.sh`, on Linux. The single-server production setup
> ([deploy.md](deploy.md), option 2) has **not yet been verified end to end**. A tested Docker
> quickstart for servers is planned. Until then, treat option 2 as a draft.

---

## Part A: run your own server (Docker)

### Option 1: on your own computer (testing)

You need Git, Docker Engine 24+ or Docker Desktop with Compose v2, and free ports 8000, 8080 and
5432. Check Docker first:

```bash
docker compose version      # expected: Docker Compose version v2.x.x
```

Start the stack:

```bash
git clone https://github.com/punitsoni22/flutter_ota_system.git
cd flutter_ota_system
cp .env.example .env              # fake, local-only values
./scripts/setup_local.sh          # builds the API, creates a LOCAL signing key, starts everything
```

The script ends with:

```
  API:    http://localhost:8000   (OpenAPI docs: /docs)
  Admin:  http://localhost:8000/admin   (key: OTA_ADMIN_API_KEY in .env)
  CDN:    http://localhost:8080/health
```

Check it:

```bash
curl http://localhost:8000/health/ready     # expected: {"status":"ok"}
docker compose ps                           # postgres, api, cdn: all "(healthy)"
```

#### Let phones reach your computer

Your phone or emulator must be able to reach the server. Edit `.env`, then run
`docker compose up -d` to apply it:

| Where the app runs | `OTA_CDN_BASE_URL` in `.env` | `OTA_SERVER_URL` for the app | Also |
|---|---|---|---|
| Android emulator | `http://10.0.2.2:8080/cdn` | `http://10.0.2.2:8000` | — |
| Phone on the same Wi-Fi | `http://<your-computer-IP>:8080/cdn` | `http://<your-computer-IP>:8000` | `PUNIT_BIND_ADDRESS=0.0.0.0` in `.env` |

Find your computer's IP: `hostname -I | awk '{print $1}'` on Linux, or
`ipconfig getifaddr en0` on macOS. It looks like `192.168.1.23`.

> [!WARNING]
> `PUNIT_BIND_ADDRESS=0.0.0.0` opens the API to your whole network, with the fake keys from
> `.env.example`. Only do this on a network you trust, and only for testing.

Plain `http://` addresses only work if the test app allows cleartext traffic
(`android:usesCleartextTraffic="true"`, as in `example_app`). Never ship that in a store build.

### Option 2: on your own server (draft, not yet verified)

[deploy.md](deploy.md) describes one Linux server running PostgreSQL, the API, an nginx file
server and Caddy for HTTPS, all with Docker Compose. Read the status note at the top of that page
first.

*Other hosting:* earlier internal tests used free cloud services (Render + Supabase). That setup is
**not recommended and not supported**; it is kept for reference in
[alternatives/render-supabase.md](alternatives/render-supabase.md).

### Connect the CLI

The `ota` command-line tool talks to your server's admin API. In the repository folder:

```bash
python3 -m venv .venv
.venv/bin/pip install -r cli/requirements.txt
alias ota="$PWD/.venv/bin/python $PWD/cli/ota.py"
export OTA_API_URL=http://localhost:8000
export OTA_API_KEY=local-dev-admin-key-not-a-secret   # = OTA_ADMIN_API_KEY in your .env
ota app list
```

Expected: a JSON list. It is `[]` on a fresh server, or shows `punit-demo` after
`./scripts/seed_demo.sh`. A wrong key prints `error 401: Invalid or missing X-API-Key`.

To keep the alias and variables, add the `alias` and `export` lines to `~/.bashrc` (Linux) or
`~/.zshrc` (macOS). Use the full path to the repository instead of `$PWD`.

Admin page: <http://localhost:8000/admin>, with the same key.

From here on, **"server"** means your server's address, for example `http://10.0.2.2:8000` for an
emulator.

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

The git URL works for anyone. With a local copy of the repository, a path works too:
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
| `command not found: ota` | Run the `alias ota=...` line (Part A, *Connect the CLI*) |
| `error 401` from `ota` | `OTA_API_KEY` is not set, or doesn't match `OTA_ADMIN_API_KEY` in the server's `.env` |
| `policy_review_required` | `ota app approve-policy <slug> --reason "..."` |
| `Release ... already exists` | `ota release delete <slug> --version <v>`, or raise the build number |
| `assets changed` / `needs a store release` | The change isn't Dart-only: make a new store build (Part B, step 5) |
| `Flutter changed` | Use the Flutter version the release was built with |
| Phone never gets the patch | Was the app built with `OTA_SERVER_URL` and `OTA_PUBLIC_KEY`? Does the phone reach the server (open `<server>/health/ready` in the phone's browser)? Is the phone on the patch's channel? Is it a **release** build (debug builds ignore patches)? |
| Patch shows but disappears after a restart | It crashed or was closed within 5 seconds of opening; check Boot failed on the admin page |
| Admin page empty | Enter the admin key and click Connect |
| Server won't start (`docker compose logs api` shows `Unsafe production settings`) | Fix the setting it names in `.env` (`OTA_ENV=production` refuses fake or unsafe values) |
| `ota release android` upload fails | `docker compose logs api` shows why. With `OTA_STORAGE_BACKEND=s3`, check the S3 keys and that both buckets exist |
