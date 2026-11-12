#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Serves the demo's product API on http://127.0.0.1:8090 from this folder:
#   /v1/products.json  (used by the store build)
#   /v2/products.json  (used after the demo patch: adds "rating")
# Both versions are served at the same time, so old and patched apps both work.
#
# For a phone connected by USB, also run once per connection:
#   adb reverse tcp:8090 tcp:8090
# The app then reaches this server at http://127.0.0.1:8090.
#
# Stop it with Ctrl+C.
set -euo pipefail
cd "$(dirname "$0")"
echo "Product API: http://127.0.0.1:8090/v1/products.json and /v2/products.json"
echo "Phone over USB: run 'adb reverse tcp:8090 tcp:8090' once."
exec python3 -m http.server 8090 --bind 127.0.0.1 --directory .
