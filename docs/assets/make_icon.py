# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
#
# Generates the Flutter OTA System icon (docs/assets and the example app launcher icons).
#   python3 docs/assets/make_icon.py      (needs Pillow)
import sys
from PIL import Image, ImageChops, ImageDraw

S = 2048  # drawn large, then downscaled for smooth edges


def rr(box, radius):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([int(v * S) for v in box], radius=int(radius * S), fill=255)
    return m


def render(size, rounded=False):
    top, bottom = (13, 148, 136), (49, 46, 129)          # teal -> indigo
    grad = Image.new("RGB", (1, S))
    for y in range(S):
        t = y / (S - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    img = grad.resize((S, S)).convert("RGBA")

    # app tile with a notch cut out of its top-right corner
    tile = ImageChops.subtract(rr((0.17, 0.35, 0.67, 0.85), 0.10), rr((0.43, 0.32, 0.70, 0.59), 0.07))
    img.paste((255, 255, 255, 255), (0, 0), tile)

    # the patch piece, tilted, arriving from the top right
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        [int(v * S) for v in (0.54, 0.19, 0.75, 0.40)], radius=int(0.055 * S), fill=(251, 191, 36, 255))
    layer = layer.rotate(-14, center=(int(0.645 * S), int(0.295 * S)), resample=Image.BICUBIC)
    img.alpha_composite(layer)

    # "over the air" motion arcs behind the patch
    d = ImageDraw.Draw(img)
    w = int(0.034 * S)
    cx, cy = int(0.645 * S), int(0.295 * S)
    for r, a in ((0.175, 230), (0.24, 150)):
        R = int(r * S)
        d.arc((cx - R, cy - R, cx + R, cy + R), 292, 338, fill=(255, 255, 255, a), width=w)

    if rounded:
        img.putalpha(rr((0, 0, 1, 1), 0.22))
    out = img.resize((size, size), Image.LANCZOS)
    return out if rounded else out.convert("RGB")


if __name__ == "__main__":
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]
    render(256, rounded=True).save(root / "docs/assets/flutter-ota-system-icon.png", optimize=True)
    # Android legacy launcher icons (rounded, transparent corners)
    res = root / "example_app/android/app/src/main/res"
    for name, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        render(px, rounded=True).save(res / f"mipmap-{name}/ic_launcher.png", optimize=True)
    # iOS app icons: square and opaque (iOS applies its own mask and forbids transparency)
    ios = root / "example_app/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for f in sorted(ios.glob("Icon-App-*.png")):
        pt, scale = f.stem.removeprefix("Icon-App-").split("@")
        px = round(float(pt.split("x")[0]) * int(scale.rstrip("x")))
        render(px).save(f, optimize=True)
    print("icons written")
