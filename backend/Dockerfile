# Flutter OTA System API image. Built locally from this repository (no pre-built images are published).
#
# Stage 1 installs the Python dependencies into a virtualenv; stage 2 copies only that virtualenv
# and the application code, so pip caches and build leftovers never reach the final image.
# The base image is pinned to an exact Python and Debian release; bump it deliberately.
# No secrets, .env files or signing keys are copied in (see backend/.dockerignore): the signing
# key lives in a volume mounted at /data/keys.
ARG PYTHON_IMAGE=python:3.13.18-slim-trixie

FROM ${PYTHON_IMAGE} AS deps
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install -r /tmp/requirements.txt

FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/opt/venv/bin:$PATH
WORKDIR /srv

COPY --from=deps /opt/venv /opt/venv
COPY alembic.ini ./
COPY migrations ./migrations
COPY app ./app

# Non-root. /data holds patch files and (local/dev only) the signing key; mount volumes there.
# The image's /data/keys is mode 700, so a new named volume mounted there starts as 700 too.
RUN useradd --uid 10001 --create-home ota && mkdir -p /data/artifacts /data/keys \
    && chown -R ota /data && chmod 700 /data/keys
USER ota

EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/health/live' % os.environ.get('PORT', '8000'), timeout=3)"]
# PORT/WEB_CONCURRENCY: optional overrides (e.g. 1 worker on a small machine); Docker Compose uses the defaults.
# Migrations run on start (under a PostgreSQL advisory lock, so several workers never race).
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --workers ${WEB_CONCURRENCY:-2} --proxy-headers --forwarded-allow-ips \"${FORWARDED_ALLOW_IPS:-127.0.0.1}\""]
