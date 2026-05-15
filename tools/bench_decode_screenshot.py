#!/usr/bin/env python3
"""Decode MiSTerbrot benchmark pixel telemetry from a screenshot."""

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit("ERROR: Pillow is required: python3 -m pip install Pillow") from exc


N_BITS = 32
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

    # 32-bit layout (MS was dropped — see docs/MR16_HANG_REPORT_V2.md):
    #   [31:28] magic 0xA
    #   [27]    sym_overflow_sticky (A2 mirror FIFO ever overflowed)
    #   [26:23] spare
    #   [22:16] scene[6:0]
    #   [15:12] iter_tier[3:0]
    #   [11:0]  f10[11:0]
    magic = (value >> 28) & 0xF
    if magic != MAGIC:
        return None

    return {
        "bits": "".join(str(bit) for bit in bits),
        "magic": magic,
        "sym_overflow": (value >> 27) & 1,
        "scene": (value >> 16) & 0x7F,
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
