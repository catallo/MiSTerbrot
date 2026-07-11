#!/usr/bin/env python3
"""Render Mandelbrot POI thumbnails for visual verification.

Reads tools/poi_master.json (a list of {name, cx, cy, zoom_level, ...}) and
writes one PNG per POI to screenshots/poi/idx_NN_name.png.

Renders at 200x150 with smooth (continuous) escape coloring to approximate
what the FPGA core's 8.56 fixed-point math will produce. Uses NumPy
vectorisation so a full 75-POI run takes <30 sec on a normal laptop.
"""

import json
import math
import os
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
OUT_DIR = ROOT / "screenshots" / "poi"

W, H = 640, 240  # matches FPGA's 640-mode native output (640×240 px)
# --vres 480 renders 640x480 references (V_OVERSAMPLE=2: vertical pitch
# step/2, matching the FPGA's 480-line modes) into screenshots/poi480/.
# FPGA's coord_generator covers a 4:3 complex-plane region regardless of mode:
#   320 mode → 320 px × step horiz, 240 px × step vert
#   640 mode → 640 px × (step/2) horiz, 240 px × step vert  (same complex extent, 2× h oversampling)
# So at W=640 we mirror 640 mode: horizontal pixel pitch is step/2, vertical is step.
H_OVERSAMPLE = 2  # 1 if W=320, 2 if W=640 — keep in sync with W
DEFAULT_STEP = 0.0125  # matches DEFAULT_STEP in auto_zoom.v (8.56 hex 0x0003333333333333)
MAX_ITER = 1024


def max_iter_for_zoom(zoom_level):
    """Deep zooms need more iterations to escape into the boundary."""
    if zoom_level < 12:
        return 1024
    if zoom_level < 18:
        return 2048
    if zoom_level < 24:
        return 4096
    return 8192


def palette_array():
    """A simple, vivid palette (256 entries) for rendering."""
    t = np.arange(256, dtype=np.float32) / 255.0
    r = (np.sin(2 * np.pi * t + 0.0) * 0.5 + 0.5) * 255
    g = (np.sin(2 * np.pi * t + 2.094) * 0.5 + 0.5) * 255
    b = (np.sin(2 * np.pi * t + 4.188) * 0.5 + 0.5) * 255
    return np.stack([r, g, b], axis=1).astype(np.uint8)


PALETTE = palette_array()


def render(cx, cy, zoom_level, w=W, h=H, max_iter=None, gallery=False):
    if max_iter is None:
        max_iter = max_iter_for_zoom(zoom_level)
    """Render a Mandelbrot view centered at (cx, cy) at the given log2 zoom level.

    `zoom_level` matches the FPGA convention: magnification = 2^zoom_level relative
    to the default view (DEFAULT_STEP = 0.0125 / pixel at zoom_level=0).
    """
    step = DEFAULT_STEP / (2.0 ** zoom_level)
    if gallery:
        # Gallery Mode framing (docs/GALLERY_DESIGN.md): 1920x1080,
        # square pixels, pitch = step * 2/9 on both axes.  Grid matches
        # the FPGA exactly: cr = cx + (x - 960)*p, ci = cy + (y - 540)*p
        # + p/2 (half-row-pitch grid shift).
        pitch = step * 2.0 / 9.0
        xs = cx + (np.arange(w) - w / 2) * pitch
        ys = cy + (np.arange(h) - h / 2) * pitch + pitch / 2
    else:
        step_x = step / H_OVERSAMPLE  # matches FPGA's step_x = step >>> 1 in 640 mode
        # vertical: 240 rows at pitch step, or 480 rows at pitch step/2
        # (same complex extent, 2x vertical sampling like the 480 modes)
        step_y = step * 240.0 / h
        xs = cx + (np.arange(w) - w / 2 + 0.5) * step_x
        ys = cy + (np.arange(h) - h / 2 + 0.5) * step_y
    X, Y = np.meshgrid(xs, ys)
    C = X + 1j * Y

    Z = np.zeros_like(C)
    iters = np.zeros(C.shape, dtype=np.int32)
    escaped_at = np.full(C.shape, max_iter, dtype=np.int32)
    abs_z2 = np.zeros(C.shape, dtype=np.float64)
    mask = np.ones(C.shape, dtype=bool)

    for n in range(max_iter):
        Z[mask] = Z[mask] * Z[mask] + C[mask]
        abs_z2[mask] = Z[mask].real ** 2 + Z[mask].imag ** 2
        newly = mask & (abs_z2 > 4.0)
        escaped_at[newly] = n
        mask &= ~newly
        if not mask.any():
            break

    # Smooth escape (mu = n - log2(log2(|z|)))
    log_z2 = np.log(np.maximum(abs_z2, 1e-30))
    mu = escaped_at - np.log2(np.maximum(log_z2 / math.log(2), 1e-30))
    mu[escaped_at >= max_iter] = -1  # interior
    # Map mu mod 256 -> palette index
    idx = np.where(mu >= 0, (mu.astype(np.int32) & 0xFF), 0)
    img = PALETTE[idx]
    img[escaped_at >= max_iter] = (0, 0, 0)  # interior = black
    return Image.fromarray(img, mode="RGB")


def safe_filename(name):
    s = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower()
    return s or "unnamed"


def main():
    global W, H, OUT_DIR
    gallery = "--gallery" in sys.argv
    if gallery:
        # 1920x1080 gallery-framed references (screenshots/poi1080)
        W, H = 1920, 1080
        OUT_DIR = ROOT / "screenshots" / "poi1080"
    if "--vres" in sys.argv:
        if gallery:
            sys.exit("--gallery and --vres are mutually exclusive")
        i = sys.argv.index("--vres")
        vres = int(sys.argv[i + 1])
        if vres == 480:
            H = 480
            OUT_DIR = ROOT / "screenshots" / "poi480"
        elif vres != 240:
            sys.exit("--vres must be 240 or 480")
    if not MASTER_JSON.exists():
        print(f"ERROR: {MASTER_JSON} not found. Run after research agent produces it.", file=sys.stderr)
        sys.exit(1)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    with open(MASTER_JSON) as f:
        pois = json.load(f)

    print(f"Rendering {len(pois)} POIs to {OUT_DIR}/")
    for i, p in enumerate(pois):
        name = p["name"]
        cx = float(p["cx"])
        cy = float(p["cy"])
        zoom = float(p["zoom_level"])
        fname = OUT_DIR / f"idx_{i:03d}_{safe_filename(name)}.png"
        try:
            img = render(cx, cy, zoom, w=W, h=H, gallery=gallery)
            img.save(fname)
            print(f"  [{i:3d}] {name:<24} ({cx:+.6f}, {cy:+.6f}) z{zoom:5.2f} -> {fname.name}")
        except Exception as e:
            print(f"  [{i:3d}] {name}: FAILED ({e})")


if __name__ == "__main__":
    main()
