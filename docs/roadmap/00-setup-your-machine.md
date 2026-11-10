# Setup — Prepare your machine

> **Roadmap status: ✅ guide.** How to prepare a Linux machine to work on Punit. The public
> repository already exists: to contribute, **fork** it instead of doing S.4 (see
> [CONTRIBUTING.md](../../CONTRIBUTING.md)). The tools in S.5 are only for **planned** phases
> (Azure, load tests).

These steps assume Ubuntu. You need **git**, **Python 3** (the backend image and CI use 3.13),
**Flutter stable ≥ 3.27 with Dart ≥ 3.12**, and **Docker** with Compose v2. Only planned phases need
the **Azure CLI** (Phase 10) and **k6** (Phase 11).

---

## S.1 Install Docker

**Why:** Docker runs PostgreSQL, Redis and the Azure Storage emulator on your laptop, so you don't need to install them one by one. The same container images later run in Azure.

**Do:**

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER      # lets you run docker without sudo
```

Then **log out and log back in** (or reboot) so the group change applies.

> If `docker-compose-v2` is not found, follow the official guide instead: https://docs.docker.com/engine/install/ubuntu/

**Check:**

```bash
docker run --rm hello-world        # prints "Hello from Docker!"
docker compose version             # prints v2.x
```

---

## S.2 Recommended VS Code extensions

- **Python** + **Pylance** (Microsoft): autocompletion and errors for the backend
- **Ruff** (Astral): shows lint problems as you type
- **Dart** + **Flutter**
- **Docker** (Microsoft): see running containers
- **YAML** (Red Hat): catches mistakes in CI files

Point VS Code at the backend's Python: `Ctrl+Shift+P` → *Python: Select Interpreter* → `backend/.venv/bin/python`.

---

## S.3 Git identity (once)

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

---

## S.4 Create the GitHub repository

**Why:** CI runs on GitHub, and Phase 10 deploys from GitHub.

1. On github.com → **New repository** → name `flutter_ota_system` → *do not* add a README, license or .gitignore (you create them in Phase 1.1).
2. Do the rest of this step **after** Phase 1.1–1.15, when there is code to push.
3. Then:

```bash
cd ~/Desktop/flutter_ota_system
git add -A
git commit -m "phase 1: foundations"
git remote add origin git@github.com:<your-user>/flutter_ota_system.git
git push -u origin main
```

**Check:** the **Actions** tab on GitHub shows the `CI` workflow running green.

---

## S.5 Later tools (install when you reach that phase)

| Tool | Phase | Install |
|---|---|---|
| Azure CLI | 10 | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` then `az login` |
| Bicep | 10 | `az bicep install` |
| k6 (load testing) | 11 | https://grafana.com/docs/k6/latest/set-up/install-k6/ |
| An Android emulator or phone | 5 | Android Studio → Device Manager |

---

## Everyday commands cheat sheet

These commands exist once you've built the `Makefile` in Phase 1.13.

```bash
make help              # list all commands
make backend-install   # (re)install backend dependencies
make backend-run       # API with auto-reload → http://localhost:8000/docs
make backend-test      # backend tests
make backend-format    # auto-fix Python style
make up / make down    # start / stop Docker stack
make logs              # watch API logs
make test              # everything CI runs
```

`http://localhost:8000/docs` is FastAPI's built-in interactive API page. Use it to try every endpoint you build.
