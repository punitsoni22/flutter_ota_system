#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds one bytecode module (patch or probe) against a recorded Phase 2 baseline:
#   1. pkg_rename prepare: copy + rename the changed packages (Dart-aware), closure/policy checks;
#   2. flutter pub get (offline, pinned to the host's lock);
#   3. dart2bytecode against the baseline's link kernel, validated against its dynamic interface;
#   4. package as .otp (Phase 1 format, plus "kind" and "name" in the manifest).
#
#   LAB=~/.cache/flutter-ota-lab ./scripts/make_module.sh <baseline-dir> <module-dir> <out.otp>
# Optional: ENTRY=lib/other_entry.dart NAME=<name> NUMBER=<n> to build a variant of one module.
# Exit code 3 = pkg_rename refused the module (unsupported change); the reason is on stderr.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
[[ $# == 3 ]] || { echo "usage: make_module.sh <baseline-dir> <module-dir> <out.otp>" >&2; exit 2; }
BASE=$(realpath "$1"); MOD=$(realpath "$2"); OTP=$(realpath -m "$3")
SDK="$LAB/flutter"
DART_BIN="$SDK/bin/cache/dart-sdk/bin/dart"
DART_AOT="$SDK/bin/cache/dart-sdk/bin/dartaotruntime"
DART_SRC="$LAB/engine/engine/src/flutter/third_party/dart"
PLATFORM="$SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill"
PUB_CACHE=${PUB_CACHE:-"$HOME/.pub-cache"}
TOOLS="$LAB/work/tools"
NAME=${NAME:-$(basename "$MOD")}
# MODULES_DIR: where modules are prepared and compiled. Module bytecode embeds this path, so a
# canonical, user-independent directory makes builds reproducible across machines (Phase 3C).
MODULES_DIR=${MODULES_DIR:-"$LAB/work/modules"}
OUT="$MODULES_DIR/$NAME"
MODPKG=$(python3 -I -c 'import sys,re; print(re.search(r"^name:\s*(\S+)", open(sys.argv[1]).read(), re.M).group(1))' "$MOD/pubspec.yaml")
ENTRY=${ENTRY:-lib/entry.dart}
# Optional extra dart2bytecode flags from module.yaml (e.g. "flags: --allow-dynamic-calls-in-dynamic-modules").
read -r -a FLAGS <<< "$(sed -n 's/^flags:[[:space:]]*//p' "$MOD/module.yaml")"

# The tools run from AOT snapshots compiled once from the pinned Dart SDK sources (much faster
# and lighter than running them from source each time).
mkdir -p "$TOOLS" "$MODULES_DIR"
snapshot() {  # <source.dart> <out.aot>
  if [[ ! -s $2 || $1 -nt $2 ]]; then
    nice -n 10 "$DART_BIN" compile aot-snapshot --packages="$DART_SRC/.dart_tool/package_config.json" -o "$2" "$1" >/dev/null
  fi
}
snapshot "$DART_SRC/pkg/dart2bytecode/bin/dart2bytecode.dart" "$TOOLS/dart2bytecode.aot"
snapshot "$HERE/tools/pkg_rename/bin/pkg_rename.dart" "$TOOLS/pkg_rename.aot"

"$DART_AOT" "$TOOLS/pkg_rename.aot" prepare --module "$MOD" --packages-root "$BASE/src/packages" \
  --host-lock "$BASE/pubspec.lock" --pub-cache "$PUB_CACHE" --policy "$HERE/tools/policy.yaml" \
  --out "$OUT" > "$OUT.rename.json" || { rc=$?; rm -f "$OUT.rename.json"; exit $rc; }
(cd "$OUT/$MODPKG" && "$SDK/bin/flutter" pub get --offline --suppress-analytics >/dev/null)
# Phase 3C: bytecode embeds source URIs (e.g. of framework mixins copied into the module). Route
# the lab directory (SDK, baselines) and the pub cache through symlinks inside MODULES_DIR so that
# no machine- or user-specific path ends up in a module.
ln -sfn "$(realpath "$LAB")" "$MODULES_DIR/.lab"
ln -sfn "$(realpath "$PUB_CACHE")" "$MODULES_DIR/.pub-cache"
python3 -I - "$OUT/$MODPKG/.dart_tool/package_config.json" "$(realpath "$LAB")" "$MODULES_DIR/.lab" \
  "$(realpath "$PUB_CACHE")" "$MODULES_DIR/.pub-cache" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); cfg = json.loads(p.read_text())
pairs = [("file://" + sys.argv[2], "file://" + sys.argv[3]), ("file://" + sys.argv[4], "file://" + sys.argv[5])]
for pkg in cfg["packages"]:
    for old, new in pairs:
        if pkg["rootUri"].startswith(old + "/"):
            pkg["rootUri"] = new + pkg["rootUri"][len(old):]
p.write_text(json.dumps(cfg, indent=2))
PY

# Optional (Phase 3): GUARD=<patch_guard.dart> runs the security guard on the prepared sources
# BEFORE any bytecode is generated. Exit code 4 = rejected (FFI, dynamic calls, mirrors, ...).
if [[ -n ${GUARD:-} ]]; then
  snapshot "$GUARD" "$TOOLS/patch_guard.aot"
  read -r MODULE_PKGS ORIGINALS < <(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(",".join([r["module"], *r["renames"].values()]), ",".join(f"{v}={k}" for k, v in r["renames"].items()) or "-")' "$OUT.rename.json")
  "$DART_AOT" "$TOOLS/patch_guard.aot" --root "$OUT" --package-config "$OUT/$MODPKG/.dart_tool/package_config.json" \
    --module-packages "$MODULE_PKGS" --original-names "${ORIGINALS/#-/}" --sdk "$SDK/bin/cache/dart-sdk" \
    --json "$OUT.guard.json" || exit $?
fi

START=$(date +%s%N)
nice -n 10 "$DART_AOT" "$TOOLS/dart2bytecode.aot" \
  --target flutter --platform "$PLATFORM" --import-dill "$BASE/link.dill" \
  --validate "$BASE/dynamic_interface.yaml" ${FLAGS[@]+"${FLAGS[@]}"} \
  --packages "$OUT/$MODPKG/.dart_tool/package_config.json" \
  -o "$OUT/module.bc" "$OUT/$MODPKG/$ENTRY"
COMPILE_MS=$(( ($(date +%s%N) - START) / 1000000 ))

python3 -I - "$BASE/baseline.json" "$MOD/module.yaml" "$OUT/module.bc" "$OTP" "$NAME" "${NUMBER:-}" "$COMPILE_MS" <<'PY'
import hashlib, json, re, struct, sys
baseline = json.load(open(sys.argv[1])); spec = open(sys.argv[2]).read()
module = open(sys.argv[3], "rb").read(); otp, name, number, compile_ms = sys.argv[4:]
field = lambda k: re.search(rf"^{k}:\s*(\S+)", spec, re.M).group(1)
manifest = {"format": 1, "runtime": baseline["runtime"], "app_id": baseline["app_id"],
            "baseline_id": baseline["baseline_id"], "kind": field("kind"), "name": name,
            "patch_number": int(number or field("number")),
            "module_sha256": hashlib.sha256(module).hexdigest(), "module_size": len(module)}
m = json.dumps(manifest, sort_keys=True).encode()
open(otp, "wb").write(b"OTAPRT01" + struct.pack(">I", len(m)) + m + module)
print(json.dumps({**manifest, "otp_size": 12 + len(m) + len(module), "compile_ms": int(compile_ms)}))
PY
