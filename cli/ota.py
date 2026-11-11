#!/usr/bin/env python3
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""ota — command-line tool for the Flutter OTA admin API.

Settings come from environment variables:
    OTA_API_URL   (default http://127.0.0.1:8000)
    OTA_API_KEY   (default dev-admin-key)

Examples:
    ota app create demo "Demo App"
    ota release create demo --platform android --version 1.0.0+1
    ota patch create demo --platform android --release 1.0.0+1 --file arm64-v8a=patch.json
    ota patch publish <patch_id> --channel dev --percent 100
    ota patch rollout <patch_id> --channel production --percent 10
    ota patch promote <patch_id> --percent 10        # staging -> production
    ota patch rollback <patch_id>
    ota patch revoke <patch_id>

Dart code patches (Android), run in the Flutter project folder:
    ota release android my-app -- --dart-define=API_BASE_URL=https://...   # build + register the store build
    ota patch android my-app --channel staging                             # rebuild, diff, upload
"""

import argparse
import json
import os
import sys
from pathlib import Path

import httpx

import android

API = os.environ.get("OTA_API_URL", "http://127.0.0.1:8000").rstrip("/")
KEY = os.environ.get("OTA_API_KEY", "dev-admin-key")


def client() -> httpx.Client:
    return httpx.Client(base_url=API, headers={"X-API-Key": KEY}, timeout=120)


def call(method: str, path: str, **kwargs):
    with client() as c:
        r = c.request(method, path, **kwargs)
    if r.status_code >= 400:
        try:
            detail = r.json().get("detail", r.text)
        except ValueError:
            detail = r.text
        sys.exit(f"error {r.status_code}: {detail}")
    return r.json()


def rollout_body(channel: str, percent: float, a) -> dict:
    """Body for publish/rollout. --force skips the server's promotion checks and needs --reason."""
    body = {"channel": channel, "rollout_percent": percent}
    if getattr(a, "force", False):
        if not (getattr(a, "reason", None) or "").strip():
            sys.exit("error: --force needs --reason \"why the checks are skipped\" (the server logs it)")
        body.update(force=True, reason=a.reason)
    return body


def show(data) -> None:
    print(json.dumps(data, indent=2, default=str))


def find_release(app: str, platform: str, version: str) -> dict:
    for release in call("GET", f"/v1/admin/apps/{app}/releases"):
        if release["platform"] == platform and release["version"] == version:
            return release
    sys.exit(f"error: release {platform} {version} not found for app '{app}'")


def parse_arch_files(values: list[str]) -> list[tuple[str, Path]]:
    out = []
    for value in values:
        arch, sep, path = value.partition("=")
        if not sep or not Path(path).is_file():
            sys.exit(f"error: --file must be ARCH=PATH to an existing file, got '{value}'")
        out.append((arch, Path(path)))
    return out


# ---- commands ----------------------------------------------------------------------------


def app_create(a):
    show(call("POST", "/v1/admin/apps", json={"slug": a.slug, "name": a.name, "distribution": a.distribution}))


def app_list(a):
    show(call("GET", "/v1/admin/apps"))


def app_policy_history(a):
    show(call("GET", f"/v1/admin/apps/{a.slug}/policy-approvals"))


def app_approve_policy(a):
    show(call("POST", f"/v1/admin/apps/{a.slug}/policy-approval", json={"approved": not a.revoke, "reason": a.reason}))


def release_create(a):
    release = call(
        "POST",
        f"/v1/admin/apps/{a.app}/releases",
        json={
            "platform": a.platform,
            "version": a.version,
            "flutter_version": a.flutter_version,
            "engine_revision": a.engine_revision,
            "runtime_abi": a.runtime_abi,
            "replace": a.replace,
        },
    )
    for arch, path in parse_arch_files(a.base or []):
        with path.open("rb") as f:
            release = call(
                "POST", f"/v1/admin/releases/{release['id']}/artifacts",
                data={"arch": arch}, files={"file": (path.name, f)},
            )
    show(release)


def release_delete(a):
    release = find_release(a.app, a.platform, a.version)
    with client() as c:
        r = c.delete(f"/v1/admin/releases/{release['id']}")
    if r.status_code != 204:
        sys.exit(f"error {r.status_code}: {r.json().get('detail', r.text)}")
    print(f"Deleted release {a.platform} {a.version} of '{a.app}' and its patches.")


def release_list(a):
    show(call("GET", f"/v1/admin/apps/{a.app}/releases"))


def patch_create(a):
    release = find_release(a.app, a.platform, a.release)
    files = parse_arch_files(a.file)
    patch = call(
        "POST", f"/v1/admin/releases/{release['id']}/patches",
        json={"artifact_format": a.format, "note": a.note},
    )
    for arch, path in files:
        data = {"arch": arch}
        if a.result_sha256:
            data["result_sha256"] = a.result_sha256
        with path.open("rb") as f:
            patch = call(
                "POST", f"/v1/admin/patches/{patch['id']}/artifacts",
                data=data, files={"file": (path.name, f)},
            )
    if a.channel:
        print(f"Created patch #{patch['number']} (id {patch['id']}); publishing it to {a.channel}", file=sys.stderr)
        patch = call("POST", f"/v1/admin/patches/{patch['id']}/publish", json=rollout_body(a.channel, a.percent, a))
    show(patch)


def patch_list(a):
    release = find_release(a.app, a.platform, a.release)
    rows = call("GET", f"/v1/admin/releases/{release['id']}/patches")
    for p in rows:
        deploys = ", ".join(f"{d['channel']}={d['rollout_percent']:g}%" for d in p["deployments"]) or "-"
        print(f"#{p['number']:<3} {p['status']:<12} {p['artifact_format']:<22} {deploys:<30} {p['id']}")


def patch_show(a):
    show(call("GET", f"/v1/admin/patches/{a.patch_id}"))


def patch_publish(a):
    show(call("POST", f"/v1/admin/patches/{a.patch_id}/publish", json=rollout_body(a.channel, a.percent, a)))


def patch_rollout(a):
    show(call("POST", f"/v1/admin/patches/{a.patch_id}/rollout", json=rollout_body(a.channel, a.percent, a)))


def patch_promote(a):
    """Move a patch that was tested on one channel (staging) to another (production).

    These checks give an early, clear error; the server enforces the same rules (KI-4).
    """
    body = rollout_body(a.to, a.percent, a)
    patch = call("GET", f"/v1/admin/patches/{a.patch_id}")
    if not any(d["channel"] == a.source and d["rollout_percent"] > 0 for d in patch["deployments"]) and not a.force:
        sys.exit(f"error: patch #{patch['number']} is not on '{a.source}'. Test it there first, or pass --force")
    failed = patch["event_counts"].get("patch_boot_failed", 0)
    if failed and not a.force:
        sys.exit(f"error: patch #{patch['number']} has {failed} boot failure(s). Fix or pass --force")
    show(call("POST", f"/v1/admin/patches/{a.patch_id}/rollout", json=body))


def patch_rollback(a):
    show(call("POST", f"/v1/admin/patches/{a.patch_id}/rollback"))


def patch_revoke(a):
    if not a.yes:
        answer = input("Revoke is permanent: this patch will never run again. Type 'revoke': ")
        if answer.strip() != "revoke":
            sys.exit("cancelled")
    show(call("POST", f"/v1/admin/patches/{a.patch_id}/revoke"))


def key_show(a):
    info = call("GET", "/v1/admin/signing-key")
    if a.dart:
        print(f"const otaPublicKeys = {{'{info['key_id']}': '{info['uncompressed_point_base64']}'}};")
    else:
        show(info)


# ---- argument parsing --------------------------------------------------------------------


def add_force_args(c) -> None:
    c.add_argument("--force", action="store_true",
                   help="Skip the staging and boot-failure checks for a protected channel (needs --reason)")
    c.add_argument("--reason", help="Why the checks are skipped; logged by the server")


def main() -> None:
    p = argparse.ArgumentParser(prog="ota", description="Flutter OTA admin CLI")
    sub = p.add_subparsers(dest="group", required=True)

    g = sub.add_parser("app").add_subparsers(dest="cmd", required=True)
    c = g.add_parser("create")
    c.add_argument("slug")
    c.add_argument("name")
    c.add_argument("--distribution", choices=["enterprise", "public_store"], default="enterprise")
    c.set_defaults(fn=app_create)
    g.add_parser("list").set_defaults(fn=app_list)
    c = g.add_parser("approve-policy", help="Record the legal/policy approval for AOT patches (ADR-0011)")
    c.add_argument("slug")
    c.add_argument("--reason", required=True)
    c.add_argument("--revoke", action="store_true", help="Withdraw the approval")
    c.set_defaults(fn=app_approve_policy)
    c = g.add_parser("policy-history", help="Policy approvals and withdrawals with their reasons, newest first")
    c.add_argument("slug")
    c.set_defaults(fn=app_policy_history)

    g = sub.add_parser("release").add_subparsers(dest="cmd", required=True)
    c = g.add_parser("create")
    c.add_argument("app")
    c.add_argument("--platform", choices=["android", "ios"], required=True)
    c.add_argument("--version", required=True, help='Store version incl. build number, e.g. "1.0.0+1"')
    c.add_argument("--flutter-version", default="")
    c.add_argument("--engine-revision", default="")
    c.add_argument("--runtime-abi", default="ota-runtime-v1")
    c.add_argument("--base", action="append", metavar="ARCH=PATH", help="Base artifact (libapp.so) per arch")
    c.add_argument("--replace", action="store_true",
                   help="Register a version again that devices still report from a deleted release")
    c.set_defaults(fn=release_create)
    c = g.add_parser("list")
    c.add_argument("app")
    c.set_defaults(fn=release_list)
    c = g.add_parser("delete", help="Remove a test release and its patches (none may be published)")
    c.add_argument("app")
    c.add_argument("--platform", choices=["android", "ios"], default="android")
    c.add_argument("--version", required=True)
    c.set_defaults(fn=release_delete)
    c = g.add_parser("android", help="Build the store APK/AAB and register it for Dart code patches")
    c.add_argument("app")
    c.add_argument("--project", default=".", help="Flutter project folder (default: current)")
    c.add_argument("--kind", choices=["aab", "apk"], default="aab", help="aab for Play, apk to install directly")
    c.add_argument("--artifact", help="Register an already built APK/AAB instead of building (pass the same build args)")
    c.add_argument("--replace", action="store_true",
                   help="Register a version again that devices still report from a deleted release")
    c.add_argument("--tree-shake-icons", action="store_true",
                   help="Keep Flutter's icon tree-shaking (smaller app, but patches can't use new icons)")
    c.set_defaults(fn=lambda a: android.release_android(a, call, client, show))

    g = sub.add_parser("patch").add_subparsers(dest="cmd", required=True)
    c = g.add_parser("create")
    c.add_argument("app")
    c.add_argument("--platform", choices=["android", "ios"], required=True)
    c.add_argument("--release", required=True, help="Release version, e.g. 1.0.0+1")
    c.add_argument("--file", action="append", required=True, metavar="ARCH=PATH")
    c.add_argument("--format", default="mock-v1", choices=["mock-v1", "aot-bidiff-android-v1", "evc-v1"])
    c.add_argument("--result-sha256", help="AOT only: hash of the rebuilt libapp.so")
    c.add_argument("--note", default="")
    c.add_argument("--channel", help="Publish right away to this channel")
    c.add_argument("--percent", type=float, default=100)
    c.set_defaults(fn=patch_create)
    c = g.add_parser("list")
    c.add_argument("app")
    c.add_argument("--platform", choices=["android", "ios"], required=True)
    c.add_argument("--release", required=True)
    c.set_defaults(fn=patch_list)
    for name, fn in (("show", patch_show), ("rollback", patch_rollback), ("revoke", patch_revoke)):
        c = g.add_parser(name)
        c.add_argument("patch_id")
        if name == "revoke":
            c.add_argument("--yes", action="store_true")
        c.set_defaults(fn=fn)
    for name, fn in (("publish", patch_publish), ("rollout", patch_rollout)):
        c = g.add_parser(name)
        c.add_argument("patch_id")
        c.add_argument("--channel", required=True)
        c.add_argument("--percent", type=float, required=True)
        add_force_args(c)
        c.set_defaults(fn=fn)

    c = g.add_parser("android", help="Rebuild the app and send its Dart changes as a code patch")
    c.add_argument("app")
    c.add_argument("--project", default=".", help="Flutter project folder (default: current)")
    c.add_argument("--release", help="Release version (default: the version in pubspec.yaml)")
    c.add_argument("--artifact", help="Use an already built APK/AAB instead of building")
    c.add_argument("--channel", help="Publish right away to this channel, e.g. staging")
    c.add_argument("--percent", type=float, default=100)
    c.add_argument("--note", default="")
    c.add_argument("--allow-native-diffs", action="store_true", help="Danger: ship although native code changed")
    c.add_argument("--allow-asset-diffs", action="store_true", help="Danger: ship although assets changed")
    c.set_defaults(fn=lambda a: android.patch_android(a, call, client, show))

    c = g.add_parser("promote", help="Move a patch tested on staging to production")
    c.add_argument("patch_id")
    c.add_argument("--from", dest="source", default="staging")
    c.add_argument("--to", default="production")
    c.add_argument("--percent", type=float, default=100)
    add_force_args(c)
    c.set_defaults(fn=patch_promote)

    g = sub.add_parser("key").add_subparsers(dest="cmd", required=True)
    c = g.add_parser("show", help="Print the public signing key")
    c.add_argument("--dart", action="store_true", help="Print as a Dart constant for the app")
    c.set_defaults(fn=key_show)

    # Everything after "--" goes to `flutter build` unchanged (e.g. --dart-define=..., --flavor).
    argv = sys.argv[1:]
    build_args = argv[argv.index("--") + 1 :] if "--" in argv else []
    args = p.parse_args(argv[: argv.index("--")] if "--" in argv else argv)
    args.build_args = build_args
    args.fn(args)


if __name__ == "__main__":
    main()
