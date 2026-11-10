#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Publishes a signed mock-v1 test patch (inert JSON: banner text + colour) to the demo channel.
#   ./scripts/publish_test_patch.sh [--banner "Text"] [--color "#RRGGBB"]
# This tests artifact publication and delivery. It does NOT ship executable Dart code.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need_docker; need_env
tools publish "$@"
