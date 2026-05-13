#!/usr/bin/env python3
"""Decode MiSTerbrot benchmark pixel telemetry from a screenshot."""

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit("ERROR: Pillow is required: python3 -m pip install Pillow") from exc


N_BITS = 24
BLOCK_W = 4
MAGIC = 0xA


def classify(rgb):
    r, g, b = rgb
    if r > 160 and g > 160 and b < 96:
        return 1
    if r < 96 and g < 96 and b > 160:
        return 0
    return None


def decode_at(img, x0, y):
    bits = []
    for idx in range(N_BITS):
        x = x0 + idx * BLOCK_W + BLOCK_W // 2
        if x >= img.width or y >= img.height:
            return None
        bit = classify(img.getpixel((x, y)))
        if bit is None:
            return None
        bits.append(bit)

    value = 0
    for bit in bits:
        value = (value << 1) | bit

    magic = (value >> 20) & 0xF
    if magic != MAGIC:
        return None

    return {
        "bits": "".join(str(bit) for bit in bits),
        "magic": magic,
        "scene": (value >> 16) & 0xF,
        "iter_tier": (value >> 12) & 0xF,
        "f10": value & 0xFFF,
        "value": value,
    }


def decode(path):
    img = Image.open(path).convert("RGB")

    # Native captures put the strip at the top-left, but the exact first sample
    # can be shifted by a pixel depending on capture/cropping. Scan a small
    # window and trust only candidates with the magic nibble.
    for y in range(min(12, img.height)):
        for x0 in range(min(8, img.width)):
            result = decode_at(img, x0, y)
            if result is not None:
                result["x"] = x0
                result["y"] = y
                return result

    raise SystemExit("ERROR: no benchmark telemetry strip found")


def main(argv):
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} SCREENSHOT.png", file=sys.stderr)
        return 2

    result = decode(argv[1])
    fps = result["f10"] / 10.0
    print(
        f"magic=0x{result['magic']:X} scene={result['scene']} "
        f"iter_tier={result['iter_tier']} "
        f"f10={result['f10']} fps={fps:.1f} bits={result['bits']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
