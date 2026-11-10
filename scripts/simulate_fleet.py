#!/usr/bin/env python3
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Simulate many devices to see rollout percentages work.

    python scripts/simulate_fleet.py --app demo --release 1.0.0+1 --channel production --devices 1000

Registers N fake installations (ids are stable, so re-running reuses them) and reports
how many are offered each patch number. Run it, change the rollout with
`ota patch rollout <id> --percent 50`, run again: the earlier devices stay in.
"""

import argparse
import collections
import concurrent.futures
import os

import httpx

API = os.environ.get("OTA_API_URL", "http://127.0.0.1:8000").rstrip("/")


def one_device(client: httpx.Client, args, i: int) -> int:
    installation_id = f"sim-{args.app}-{i:08d}"
    r = client.post(
        "/v1/devices/register",
        json={
            "app": args.app,
            "installation_id": installation_id,
            "platform": "android",
            "arch": args.arch,
            "release_version": args.release,
            "channel": args.channel,
        },
    )
    r.raise_for_status()
    token = r.json()["access_token"]
    r = client.get(
        "/v1/updates/check",
        params={
            "platform": "android",
            "arch": args.arch,
            "release_version": args.release,
            "channel": args.channel,
            "current_patch_number": 0,
            "supported_formats": "mock-v1",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    r.raise_for_status()
    body = r.json()
    return body["patch"]["number"] if body["update_available"] else 0


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True)
    p.add_argument("--release", required=True)
    p.add_argument("--channel", default="production")
    p.add_argument("--arch", default="arm64-v8a")
    p.add_argument("--devices", type=int, default=1000)
    p.add_argument("--workers", type=int, default=16)
    args = p.parse_args()

    counts: collections.Counter[int] = collections.Counter()
    with httpx.Client(base_url=API, timeout=30) as client:
        with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
            for number in pool.map(lambda i: one_device(client, args, i), range(args.devices)):
                counts[number] += 1

    for number, n in sorted(counts.items()):
        label = "no update" if number == 0 else f"patch {number}"
        print(f"{label:<12} {n:>7}  ({n / args.devices:.1%})")


if __name__ == "__main__":
    main()
