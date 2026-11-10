#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Seeds demo data: application punit-demo, channel dev, release android 1.0.0+1 (from .env).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need_docker; need_env
tools seed
