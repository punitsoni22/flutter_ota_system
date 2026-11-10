# Phase 4 — Artifact storage (1–2 pw)

> **Roadmap status: 🟡 partial.**
> - ✅ Content-addressed, immutable storage (`backend/app/storage.py`): local disk (served by
>   nginx) or any **S3-compatible** bucket. Uploads via the CLI.
> - 🟡 Uploads go straight to the API as multipart (`POST /v1/admin/patches/{id}/artifacts`),
>   not through the prepare/commit flow in 4.5.
> - 🔭 **Azure Blob Storage is not implemented.** Neither are SAS / short-lived download URLs.

**Goal:** patch files live in Blob Storage under names that never change, and devices download them without going through the API.

**New concepts:** Azure Blob Storage, Azurite (local emulator), SAS tokens (temporary signed URLs), content addressing.

Branch: `git switch -c phase-4-storage`.

---

## 4.1 Understand the flow

```
CI (upload)                        API                         Device
───────────                        ───                         ──────
1. POST .../artifacts:prepare ───► returns a short-lived
                                   write-only upload URL
2. PUT file bytes directly ──────────────────────────► Blob
3. POST .../artifacts:commit ────► server re-reads the blob,
                                   recomputes SHA-256 + size,
                                   inserts the DB row only if
                                   they match
                                                      4. GET /updates/check
                                                         → artifact URL (CDN)
                                                      5. GET bytes ──► CDN ──► Blob
```

The API never carries the bytes in either direction. It only hands out URLs and checks results.

---

## 4.2 Add the SDK and settings

**Do:** add `"azure-storage-blob[aio]>=12.20"` and `"azure-identity>=1.17"` to dependencies. Settings:

```python
# Azurite's well-known development connection string (public, not a secret).
blob_connection_string: str | None = "UseDevelopmentStorage=true;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1"
blob_account_url: str | None = None     # Azure: https://<account>.blob.core.windows.net
blob_container: str = "artifacts"
cdn_base_url: str = "http://127.0.0.1:10000/devstoreaccount1/artifacts"
```

In Azure you use `blob_account_url` + `DefaultAzureCredential()` (managed identity, no keys). Locally you use the connection string. Inside Docker Compose, the host is `azurite`, not `127.0.0.1`. Set it in `docker-compose.yml` under `api.environment`.

---

## 4.3 The storage adapter

**Why:** the rest of the code shouldn't care whether it is Azurite or Azure.

**Do:** `app/storage/blob.py` with one class and four methods:

```python
class BlobStorage:
    async def ensure_container(self) -> None: ...
    async def upload_url(self, key: str, ttl_minutes: int = 15) -> str: ...  # write-only SAS
    async def sha256_and_size(self, key: str) -> tuple[str, int]: ...        # streams, never loads all
    def public_url(self, key: str) -> str: ...                                # cdn_base_url + key
```

Hints:
- `BlobServiceClient.from_connection_string(...)` locally, `BlobServiceClient(account_url, credential=DefaultAzureCredential())` in Azure.
- SAS locally: `generate_blob_sas(..., account_key=..., permission=BlobSasPermissions(create=True, write=True), expiry=...)`.
- SAS in Azure: get a **user delegation key** first (`get_user_delegation_key`), then pass `user_delegation_key=` instead of `account_key=`. Microsoft recommends this over account keys.
- Hashing: `downloader = await blob.download_blob()` then `async for chunk in downloader.chunks(): h.update(chunk)`.

---

## 4.4 Key naming (content addressing)

**Do:** one helper, used everywhere:

```python
def patch_blob_key(app_id, patch_id, platform, arch, payload_sha256) -> str:
    return f"apps/{app_id}/patches/{patch_id}/{platform}/{arch}/{payload_sha256}.patch"

def release_blob_key(app_id, release_id, platform, arch, sha256) -> str:
    return f"apps/{app_id}/releases/{release_id}/{platform}/{arch}/base/{sha256}.bin"
```

Because the file's hash is in its name, the same name always means the same bytes. CDN caches can keep it forever.

---

## 4.5 Prepare / commit endpoints

**Do:**
- `POST /v1/admin/patches/{id}/artifacts:prepare` with body `{arch, payload_sha256, size_bytes, ...}` → returns `{blob_key, upload_url}`.
- `POST /v1/admin/patches/{id}/artifacts:commit` with the full artifact metadata → the server calls `sha256_and_size(blob_key)`. If both match the claimed values, insert `patch_artifacts`. Otherwise return 422 and don't insert.
- Same pair for release base artifacts.

When uploading, use `overwrite=False` (or header `If-None-Match: *`) so an existing blob can **never** be replaced.

**Check:** an integration test that prepares, uploads with `httpx.put(upload_url, content=..., headers={"x-ms-blob-type": "BlockBlob"})`, and commits. Then a second test that commits with a wrong hash and gets 422.

For testcontainers, add Azurite: `from testcontainers.azurite import AzuriteContainer`.

---

## 4.6 Download endpoint and cache headers

**Do:**
- `GET /v1/patches/{id}/download?arch=...` (device auth) → **302 redirect** to `public_url(blob_key)`. It must never stream the file itself.
- On upload, set `content_settings=ContentSettings(cache_control="public, max-age=31536000, immutable")`.
- For local development, create the container with public read access (`public_access="blob"`) so the redirect URL works like a CDN.

**Check:** `curl -L -H "Authorization: Bearer $TOKEN" localhost:8000/v1/patches/<id>/download?arch=arm64-v8a -o p.bin && sha256sum p.bin` matches.

---

## 4.7 A tiny CLI to upload patches

**Why:** you'll upload many test patches. Doing it by hand with curl gets old fast.

**Do:** create `patch_engine/` as a small Python package with a `typer` CLI:

```bash
ota-patch upload --api http://localhost:8000 --admin-key ... \
  --patch-id <id> --arch arm64-v8a --file ./config.json
```

It hashes the file, calls prepare, PUTs the bytes, and calls commit. It is extended with signing in Phase 6.

---

## Phase 4 is done when

- [ ] Uploading goes straight to Blob, and the API verifies hash and size before registering
- [ ] Blobs cannot be overwritten
- [ ] `/download` redirects, and the file hash matches
- [ ] `/updates/check` returns a real, downloadable URL
