#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Owner-side: builds the toolchain overlay archive from the lab toolchain and writes a signed
# toolchain index next to it. Nothing is uploaded or published.
#
#   LAB=~/.cache/flutter-ota-lab OUT=/path/to/mirror ./tools/toolchain/build_bundle.sh
#
# Environment (all optional):
#   LAB        lab toolchain made by prototypes/bytecode_engine/scripts/prepare_toolchain.sh
#              (default ~/.cache/flutter-ota-lab)
#   OUT        output mirror folder (default $LAB/toolchain-mirror); contains index.json and
#              overlays/<name>-linux-x64.tar.gz
#   KEY_DIR    where the toolchain signing key lives (default $LAB/keys/toolchain). It is created on
#              the first run. It must be OUTSIDE the repository and must never be committed.
#   KEY_ID     signing key id (default flutter-ota-toolchain-dev)
#   NAME       toolchain id (default flutter-<FLUTTER_VERSION>-ota.1)
#   RELEASE_LAYOUT=1   write the files for a GitHub release, all flat in OUT: toolchain-index.json,
#              the overlay, toolchain-manifest.json (versions, engine build ID, SHA-256) and SHA256SUMS
#   SDK_URL / SDK_SHA256 / SDK_SIZE   the stock Flutter SDK archive; by default the official
#              release archive, with the SHA-256 from the official releases_linux.json.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
PINS="$REPO/prototypes/bytecode_engine/pins.env"
# shellcheck source=../../prototypes/bytecode_engine/pins.env
source "$PINS"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
OUT=${OUT:-"$LAB/toolchain-mirror"}
KEY_DIR=${KEY_DIR:-"$LAB/keys/toolchain"}
KEY_ID=${KEY_ID:-flutter-ota-toolchain-dev}
NAME=${NAME:-"flutter-$FLUTTER_VERSION-ota.1"}
DART=${DART:-"$LAB/flutter/bin/cache/dart-sdk/bin/dart"}

case "$(realpath -m "$KEY_DIR")/" in
  "$REPO"/*) echo "KEY_DIR must be outside the repository" >&2; exit 1 ;;
esac

if [[ -z ${SDK_SHA256:-} ]]; then
  BASE=https://storage.googleapis.com/flutter_infra_release/releases
  REL=$(curl -fsSL "$BASE/releases_linux.json")
  ARCHIVE=$(printf '%s' "$REL" | python3 -I -c 'import json,sys; v=sys.argv[1]; c=sys.argv[2]
d=json.load(sys.stdin); r=[x for x in d["releases"] if x["version"]==v and x["hash"]==c]
print(r[0]["archive"], r[0]["sha256"]) if r else sys.exit("release not found")' "$FLUTTER_VERSION" "$FLUTTER_COMMIT")
  SDK_URL=${SDK_URL:-"$BASE/${ARCHIVE% *}"}
  SDK_SHA256=${ARCHIVE#* }
fi
SDK_URL=${SDK_URL:?set SDK_URL together with SDK_SHA256}
if [[ -z ${SDK_SIZE:-} ]]; then
  SDK_SIZE=$(curl -fsSI "$SDK_URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)
fi
[[ -n $SDK_SHA256 && -n $SDK_SIZE ]] || { echo "SDK_URL/SDK_SHA256/SDK_SIZE unknown" >&2; exit 1; }

LAYOUT_ARGS=()
INDEX_FILE=$OUT/index.json
if [[ -n ${RELEASE_LAYOUT:-} ]]; then
  LAYOUT_ARGS=(--release-layout)
  INDEX_FILE=$OUT/toolchain-index.json
fi

cd "$HERE"
nice "$DART" pub get >/dev/null
if [[ ! -f $KEY_DIR/$KEY_ID.key ]]; then
  nice "$DART" run bin/toolchain_bundle.dart keygen --key-dir "$KEY_DIR" --key-id "$KEY_ID"
fi
nice "$DART" run bin/toolchain_bundle.dart build --lab "$LAB" --pins "$PINS" --repo "$REPO" \
  --name "$NAME" --out-dir "$OUT" --key-dir "$KEY_DIR" --key-id "$KEY_ID" \
  --sdk-url "$SDK_URL" --sdk-sha256 "$SDK_SHA256" --sdk-size "$SDK_SIZE" "${LAYOUT_ARGS[@]}"
nice "$DART" run bin/toolchain_bundle.dart verify --index "$INDEX_FILE" --pub "$KEY_DIR/$KEY_ID.pub" --key-id "$KEY_ID"
echo
echo "Developers using this mirror run:"
echo "  flutter_ota config set toolchain-index-url file://$INDEX_FILE"
echo "  flutter_ota config add-toolchain-key $KEY_ID $(cat "$KEY_DIR/$KEY_ID.pub")"
