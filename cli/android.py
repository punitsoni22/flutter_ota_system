# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""`ota release android` and `ota patch android`: Dart code patches for Android.

release: build the store APK/AAB, register it, upload its libapp.so (all compiled Dart code) per ABI
         and a fingerprint of everything else in the build.
patch:   rebuild with the same arguments, refuse anything a patch can't carry (Flutter version,
         native libraries, Java/Kotlin, manifest, resources, assets), diff each libapp.so against
         the release's and upload the diffs as one signed patch.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

import otadiff

RUNTIME_ABI = "ota-aot-android-1"
FORMAT = "aot-bidiff-android-v1"
ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64", "x86")


def flutter() -> str:
    return os.environ.get("FLUTTER", "flutter")


def flutter_info() -> dict:
    out = subprocess.run([flutter(), "--version", "--machine"], capture_output=True, text=True, check=True).stdout
    info = json.loads(out[out.index("{") :])
    return {"frameworkVersion": info["frameworkVersion"], "engineRevision": info["engineRevision"]}


def store_version(project: Path, build_args: list[str]) -> str:
    """The version the app reports: pubspec.yaml, unless --build-name/--build-number override it."""
    text = (project / "pubspec.yaml").read_text()
    match = re.search(r"^version:\s*([^\s#]+)", text, re.M)
    if not match:
        sys.exit("error: no version: in pubspec.yaml")
    name, _, number = match.group(1).partition("+")
    for arg in build_args:
        if arg.startswith("--build-name="):
            name = arg.split("=", 1)[1]
        elif arg.startswith("--build-number="):
            number = arg.split("=", 1)[1]
    return f"{name}+{number}" if number else name


def build(project: Path, kind: str, build_args: list[str]) -> Path:
    target = "apk" if kind == "apk" else "appbundle"
    cmd = [flutter(), "build", target, "--release", *build_args]
    print("$ " + " ".join(cmd), flush=True)
    started = time.time()
    if subprocess.run(cmd, cwd=project).returncode != 0:
        sys.exit("error: flutter build failed")
    outputs = project / "build" / "app" / "outputs"
    built = [p for p in outputs.rglob(f"*.{kind}") if p.stat().st_mtime >= started - 1]
    if not built:
        sys.exit(f"error: flutter build produced no .{kind} under {outputs}")
    return max(built, key=lambda p: p.stat().st_mtime)


def inspect(artifact: Path) -> tuple[dict[str, bytes], dict]:
    """libapp.so per ABI, and hashes of everything else that a code patch must leave unchanged."""
    kind = artifact.suffix.lstrip(".")
    base = "base/" if kind == "aab" else ""
    libs: dict[str, bytes] = {}
    native, code, assets = {}, {}, {}
    other = {}
    with zipfile.ZipFile(artifact) as z:
        for name in z.namelist():
            if name.endswith("/") or name.startswith("META-INF/") or "/META-INF/" in name:
                continue  # directories, and signatures that differ on every build
            data = z.read(name)
            sha = hashlib.sha256(data).hexdigest()
            rel = name.removeprefix(base)
            if rel.startswith("lib/") and rel.endswith("/libapp.so"):
                libs[rel.split("/")[1]] = data
            elif rel.startswith("lib/"):
                native[rel] = sha
            elif rel.endswith(".dex"):
                code[rel] = sha
            elif rel.startswith("assets/flutter_assets/"):
                assets[rel.removeprefix("assets/flutter_assets/")] = sha
            elif rel in ("AndroidManifest.xml", "manifest/AndroidManifest.xml", "resources.arsc", "resources.pb"):
                other[rel] = sha
    if not libs:
        sys.exit(f"error: {artifact} has no lib/<abi>/libapp.so. Is it a release build?")
    fingerprint = {
        "kind": kind,
        "libapp": {abi: hashlib.sha256(data).hexdigest() for abi, data in libs.items()},
        "native": native,
        "code": code,
        "android": other,
        "assets": assets,
    }
    return libs, fingerprint


def compare(old: dict, new: dict) -> tuple[list[str], list[str]]:
    """What changed outside Dart: (native/Android changes, Flutter asset changes)."""

    def diff(section: str) -> list[str]:
        a, b = old.get(section, {}), new.get(section, {})
        return [f"{'changed' if k in a and k in b else 'added' if k in b else 'removed'}: {k}"
                for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]

    return diff("native") + diff("code") + diff("android"), diff("assets")


# ---- commands ----------------------------------------------------------------------------


def release_android(a, call, client, show):
    project = Path(a.project).resolve()
    build_args = list(a.build_args)
    # Icon tree-shaking keeps only the icons the Dart code uses, so a patch that uses one more icon
    # would change the font asset, which a patch can't carry. Ship the full icon font instead.
    if not a.tree_shake_icons and "--no-tree-shake-icons" not in build_args:
        build_args.append("--no-tree-shake-icons")
    version = store_version(project, build_args)
    info = flutter_info()
    if a.artifact:
        artifact = Path(a.artifact)
        if not artifact.is_file():
            sys.exit(f"error: {artifact} not found")
    else:
        artifact = build(project, a.kind, build_args)
    libs, fingerprint = inspect(artifact)
    fingerprint.update(build_args=build_args, flutter=info)

    release = call("POST", f"/v1/admin/apps/{a.app}/releases", json={
        "platform": "android",
        "version": version,
        "flutter_version": info["frameworkVersion"],
        "engine_revision": info["engineRevision"],
        "runtime_abi": RUNTIME_ABI,
        "fingerprint": fingerprint,
        "replace": a.replace,
    })
    for abi, data in sorted(libs.items()):
        release = call("POST", f"/v1/admin/releases/{release['id']}/artifacts",
                       data={"arch": abi}, files={"file": ("libapp.so", data)})
    print(f"\nRelease {version} registered for '{a.app}' ({', '.join(sorted(libs))}).")
    print(f"Ship exactly this file (store upload or install): {artifact}")
    print("Patches are diffed against its code, so a rebuilt file needs a new release.")


def patch_android(a, call, client, show):
    project = Path(a.project).resolve()
    releases = call("GET", f"/v1/admin/apps/{a.app}/releases")
    version = a.release
    if not version:
        # The release's own build args may set --build-name/--build-number, so try both readings.
        plain = store_version(project, [])
        version = next((r["version"] for r in releases if r["platform"] == "android"
                        and r["version"] == store_version(project, r["fingerprint"].get("build_args", []))), plain)
    release = next((r for r in releases if r["platform"] == "android" and r["version"] == version), None)
    if release is None:
        sys.exit(f"error: no android release {version} for '{a.app}'. Run `ota release android` first.")
    if release["runtime_abi"] != RUNTIME_ABI or not release["fingerprint"]:
        sys.exit(f"error: release {version} was not made with `ota release android`, so it can't take code patches")
    old = release["fingerprint"]

    info = flutter_info()
    if info != old["flutter"]:
        sys.exit(f"error: Flutter changed ({old['flutter']['frameworkVersion']} → {info['frameworkVersion']}). "
                 "A patch must use the exact Flutter the release used.")
    build_args = old.get("build_args", [])
    artifact = Path(a.artifact) if a.artifact else build(project, old["kind"], build_args)
    libs, new = inspect(artifact)

    native, assets = compare(old, new)
    if native and not a.allow_native_diffs:
        sys.exit("error: this change needs a store release, a patch can only change Dart code:\n  "
                 + "\n  ".join(native[:30]))
    if assets and not a.allow_asset_diffs:
        hint = ("\n  (MaterialIcons changes when you use a new icon: build releases with "
                "--no-tree-shake-icons to avoid that)" if any("MaterialIcons" in x for x in assets) else "")
        sys.exit("error: assets changed, and a patch can only change Dart code:\n  " + "\n  ".join(assets[:30]) + hint)

    bases = {art["arch"]: art for art in release["artifacts"]}
    if all(new["libapp"].get(abi) == old["libapp"].get(abi) for abi in bases):
        sys.exit("Nothing to patch: the Dart code is identical to the release.")

    patch = call("POST", f"/v1/admin/releases/{release['id']}/patches", json={"artifact_format": FORMAT, "note": a.note})
    with tempfile.TemporaryDirectory() as tmp:
        for abi, base_info in sorted(bases.items()):
            if abi not in libs:
                sys.exit(f"error: the new build has no {abi} libapp.so")
            with client() as c:
                r = c.get(base_info["url"])
            if r.status_code != 200 or hashlib.sha256(r.content).hexdigest() != base_info["sha256"]:
                sys.exit(f"error: could not download the release's {abi} base")
            started = time.time()
            data = otadiff.diff(r.content, libs[abi])
            if otadiff.patch(r.content, data) != libs[abi]:
                sys.exit(f"error: {abi} diff did not round-trip")
            path = Path(tmp) / f"{abi}.otadiff"
            path.write_bytes(data)
            print(f"  {abi}: libapp.so {len(libs[abi]) / 1e6:.1f} MB → patch {len(data) / 1e3:.0f} KB "
                  f"({time.time() - started:.0f}s)", flush=True)
            with path.open("rb") as f:
                patch = call("POST", f"/v1/admin/patches/{patch['id']}/artifacts",
                             data={"arch": abi, "result_sha256": new["libapp"][abi]},
                             files={"file": (path.name, f)})
    if a.channel:
        patch = call("POST", f"/v1/admin/patches/{patch['id']}/publish",
                     json={"channel": a.channel, "rollout_percent": a.percent})
    where = f"published to {a.channel} at {a.percent:g}%" if a.channel else "draft (publish it from the admin page)"
    print(f"\nPatch #{patch['number']} for {version}: {where}. id {patch['id']}")
