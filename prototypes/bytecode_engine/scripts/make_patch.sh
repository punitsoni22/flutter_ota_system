#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Compiles the patched package (patch/greeting_v2) to a Dart BYTECODE module against a recorded
# baseline, validates it against the host's dynamic interface, and packages a .otp patch file.
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/make_patch.sh <baseline-dir> <patch-number> <out.otp>
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../pins.env
source "$HERE/pins.env"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
[[ $# == 3 ]] || { echo "usage: make_patch.sh <baseline-dir> <patch-number> <out.otp>" >&2; exit 2; }
BASE=$(realpath "$1"); NUMBER=$2; OTP=$(realpath -m "$3")
SDK="$LAB/flutter"
DART_BIN="$SDK/bin/cache/dart-sdk/bin/dart"
DART_SRC="$LAB/engine/engine/src/flutter/third_party/dart"
PLATFORM="$SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill"
WORK="$LAB/work/patch-$NUMBER"

rm -rf "$WORK" && mkdir -p "$WORK"
(cd "$HERE/patch/greeting_v2" && tar --exclude=.dart_tool --exclude=pubspec.lock -cf - .) | tar -xf - -C "$WORK"
(cd "$WORK" && "$DART_BIN" pub get --offline >/dev/null 2>&1 || "$DART_BIN" pub get >/dev/null)

# dart2bytecode is run from the pinned Dart SDK source (it is not shipped in any SDK).
"$DART_BIN" --packages="$DART_SRC/.dart_tool/package_config.json" \
  "$DART_SRC/pkg/dart2bytecode/bin/dart2bytecode.dart" \
  --target flutter --platform "$PLATFORM" --import-dill "$BASE/link.dill" \
  --validate "$LAB/work/dynamic_interface.yaml" \
  --packages "$WORK/.dart_tool/package_config.json" \
  -o "$WORK/module.bc" "$WORK/lib/entry.dart"

python3 -I - "$BASE/baseline.json" "$NUMBER" "$WORK/module.bc" "$OTP" <<'EOF'
import hashlib, json, struct, sys
baseline = json.load(open(sys.argv[1])); number = int(sys.argv[2])
module = open(sys.argv[3], "rb").read()
manifest = {"format": 1, "runtime": baseline["runtime"], "app_id": baseline["app_id"],
            "baseline_id": baseline["baseline_id"], "patch_number": number,
            "module_sha256": hashlib.sha256(module).hexdigest(), "module_size": len(module)}
m = json.dumps(manifest, sort_keys=True).encode()
open(sys.argv[4], "wb").write(b"OTAPRT01" + struct.pack(">I", len(m)) + m + module)
print(json.dumps(manifest, indent=2))
EOF
ls -l "$WORK/module.bc" "$OTP"
