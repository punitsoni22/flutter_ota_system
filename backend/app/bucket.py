# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

"""Deterministic rollout buckets (ADR-0004).

The same device always gets the same bucket for the same patch, so when a rollout grows
from 1% to 10%, the first 1% stays in. Never use random() for this.
"""

import hashlib
import hmac

from app.canonical import length_prefixed

BUCKETS = 10_000


def rollout_bucket(secret: str, application_id: str, installation_id: str, cohort_seed: str) -> int:
    digest = hmac.new(
        secret.encode(),
        length_prefixed(application_id, installation_id, cohort_seed),
        hashlib.sha256,
    ).digest()
    return int.from_bytes(digest[:8], "big") % BUCKETS


def is_in_rollout(bucket: int, rollout_bps: int) -> bool:
    return bucket < rollout_bps
