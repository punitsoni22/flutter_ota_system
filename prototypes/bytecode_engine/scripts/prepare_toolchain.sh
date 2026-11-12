#!/usr/bin/env bash
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Turns the lab's Flutter 3.47.9 SDK into the prototype toolchain, without touching any global
# installation:
#   - installs our gen_snapshot (interpreter-enabled) into the LAB SDK's artifact cache
#     (the stock binary is kept as gen_snapshot.stock);
#   - creates a local Maven mirror whose arm64 engine artifact contains our libflutter.so; the
#     embedding jar is the unmodified official one.
# Builds then use FLUTTER_STORAGE_BASE_URL=file://$LAB/mirror and GRADLE_USER_HOME=$LAB/gradle
# (see build_app.sh), so no cached stock engine can be picked up by mistake.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../pins.env
source "$HERE/pins.env"
LAB=${LAB:-"$HOME/.cache/flutter-ota-lab"}
SDK="$LAB/flutter"
OUT="$LAB/engine/engine/src/out/android_release_arm64"
V="1.0.0-$ENGINE_COMMIT"
OFFICIAL=https://storage.googleapis.com/download.flutter.io/io/flutter
MIRROR="$LAB/mirror/download.flutter.io/io/flutter"

[[ $(git -C "$SDK" rev-parse HEAD) == "$FLUTTER_COMMIT" ]] || { echo "lab SDK is not at the pinned commit" >&2; exit 1; }
[[ $(cat "$SDK/bin/cache/engine.stamp") == "$ENGINE_COMMIT" ]] || { echo "lab SDK engine stamp mismatch" >&2; exit 1; }
"$SDK/bin/flutter" precache --android --suppress-analytics >/dev/null

GS="$SDK/bin/cache/artifacts/engine/android-arm64-release/linux-x64/gen_snapshot"
[[ -f $GS.stock ]] || cp -p "$GS" "$GS.stock"
install -m 0755 "$OUT/clang_x64/gen_snapshot" "$GS"

for a in arm64_v8a_release flutter_embedding_release; do mkdir -p "$MIRROR/$a/$V"; done
# Embedding: the unmodified official artifact.
for ext in jar pom; do
  curl -fsSL -o "$MIRROR/flutter_embedding_release/$V/flutter_embedding_release-$V.$ext" \
    "$OFFICIAL/flutter_embedding_release/$V/flutter_embedding_release-$V.$ext"
done
# Engine: the official POM, and a jar with the same layout as the official one but our library.
curl -fsSL -o "$MIRROR/arm64_v8a_release/$V/arm64_v8a_release-$V.pom" \
  "$OFFICIAL/arm64_v8a_release/$V/arm64_v8a_release-$V.pom"
curl -fsSL -o "$LAB/arm64_v8a_release.stock.jar" "$OFFICIAL/arm64_v8a_release/$V/arm64_v8a_release-$V.jar"
WORK=$(mktemp -d)
mkdir -p "$WORK/lib/arm64-v8a"
cp "$OUT/lib.stripped/libflutter.so" "$WORK/lib/arm64-v8a/libflutter.so"
(cd "$WORK" && rm -f "$MIRROR/arm64_v8a_release/$V/arm64_v8a_release-$V.jar" && \
  python3 -I -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED); z.write("lib/arm64-v8a/libflutter.so"); z.close()' \
  "$MIRROR/arm64_v8a_release/$V/arm64_v8a_release-$V.jar")
rm -rf "$WORK"
echo "stock jar entries:  $(python3 -I -c 'import zipfile,sys; print(zipfile.ZipFile(sys.argv[1]).namelist())' "$LAB/arm64_v8a_release.stock.jar")"
echo "our jar entries:    $(python3 -I -c 'import zipfile,sys; print(zipfile.ZipFile(sys.argv[1]).namelist())' "$MIRROR/arm64_v8a_release/$V/arm64_v8a_release-$V.jar")"
sha256sum "$GS" "$GS.stock" "$OUT/lib.stripped/libflutter.so"
