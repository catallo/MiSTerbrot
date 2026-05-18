#!/usr/bin/env python3
"""Joint sim: coord_generator + iter_quad + A2 mirror + framebuffer.

Renders a whole frame at the catalogue coords using the exact same
8.56 fixed-point arithmetic as the RTL.  If this sim reproduces the
FPGA's pink-band artifact, the bug is in the modelled logic (and
we've found it).  If the sim renders cleanly, the bug is in
something we haven't modelled (timing, mirror FIFO order, FB
init/contention, pipeline backpressure, etc.).

Usage:
  python3 sim_frame.py        # MERCATOR P189 z=25 default
  python3 sim_frame.py P38    # MERCATOR P38 z=22
  python3 sim_frame.py CAULI  # EJS CAULI z=17.34
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from golden import iter_quad_golden, to_8_56, from_8_56, MASK64

from PIL import Image

# Match RTL DEFAULT_STEP = 0x0003333333333333 in 8.56
DEFAULT_STEP_RAW = 0x0003333333333333

POIS = {
    "P189":  dict(cx=-1.7487645202, cy=0.0, z=25.0,  max_iter=1024),
    "P38":   dict(cx=-1.7487645763, cy=0.0, z=22.0,  max_iter=512),
    "CAULI": dict(cx=-1.7487645,    cy=0.0, z=17.34, max_iter=2048),
}


def xtc_palette(idx: int) -> tuple[int, int, int]:
    """Match color_mapper.v XTC (palette index 27)."""
    if idx < 43:
        r, g, b = 255, 182 + (idx >> 1), 193 + (idx >> 2)
    elif idx < 86:
        r, g, b = 255, 215 + (idx >> 1), 0 + (idx >> 2)
    elif idx < 129:
        r, g, b = 181, 126 + (idx >> 1), 220 + (idx >> 1)
    elif idx < 172:
        r, g, b = 135 + (idx >> 1), 206 + (idx >> 1), 235
    elif idx < 215:
        r, g, b = 255, 218 + (idx >> 1), 185 + (idx >> 1)
    else:
        r, g, b = 255, 105 + (idx >> 1), 180 + (idx >> 1)
    return min(r, 255), min(g, 255), min(b, 255)


def mask_6bit(rgb):
    return tuple(c & 0xFC for c in rgb)


def sim_frame(cx: float, cy: float, z: float, max_iter: int, mode_640: bool = True):
    """Render one full frame.  Returns (iter_map, esc_map) both H×W lists."""
    W = 640 if mode_640 else 320
    H = 240

    step_raw = DEFAULT_STEP_RAW >> int(z)
    # Fractional zoom: shift by floor(z), then divide by 2^frac. RTL stores
    # step as an 8.56 reg, so the catalogue's bench_step is just to_8_56(step)
    # — but for non-integer z, we need to be careful.  Use the float and
    # convert to 8.56 (same as the catalogue would).
    step_f = (DEFAULT_STEP_RAW / (1 << 56)) / (2 ** z)
    step_raw = to_8_56(step_f)
    step_x_raw = (step_raw >> 1) if mode_640 else step_raw

    cy_raw = to_8_56(cy)
    sym = (cy_raw == 0)
    last_row = 119 if sym else 239

    # Match coord_generator.v exactly:
    #   half_h_offset = (step << 7) + (step << 5)        // 160 * step
    #   half_v_offset = (step << 7) - (step << 3)        // 120 * step
    half_h_offset_raw = ((step_raw << 7) + (step_raw << 5)) & MASK64
    half_v_offset_raw = ((step_raw << 7) - (step_raw << 3)) & MASK64

    cx_raw = to_8_56(cx)
    cr_start_raw = (cx_raw - half_h_offset_raw) & MASK64
    # Half-step shift in ci so no row lands on ci=0 exactly
    ci_start_raw = (cy_raw - half_v_offset_raw + (step_raw >> 1)) & MASK64

    iter_map = [[0] * W for _ in range(H)]
    esc_map = [[False] * W for _ in range(H)]

    t0 = time.time()
    ci_raw = ci_start_raw
    for py in range(last_row + 1):
        cr_raw = cr_start_raw
        for px in range(W):
            cr_f = from_8_56(cr_raw)
            ci_f = from_8_56(ci_raw)
            it, esc = iter_quad_golden(cr_f, ci_f, max_iter)
            iter_map[py][px] = it
            esc_map[py][px] = esc
            cr_raw = (cr_raw + step_x_raw) & MASK64
        ci_raw = (ci_raw + step_raw) & MASK64
        if (py + 1) % 10 == 0:
            elapsed = time.time() - t0
            rate = (py + 1) * W / elapsed
            eta = (last_row + 1 - py - 1) * W / rate
            print(f"  row {py+1}/{last_row+1} done, {elapsed:.0f}s elapsed, ~{eta:.0f}s left ({rate:.0f} px/s)")

    if sym:
        for py in range(120):
            for px in range(W):
                iter_map[239 - py][px] = iter_map[py][px]
                esc_map[239 - py][px] = esc_map[py][px]

    return iter_map, esc_map


def render_to_png(iter_map, esc_map, out_path, six_bit=True):
    H = len(iter_map)
    W = len(iter_map[0])
    pixels = []
    for y in range(H):
        for x in range(W):
            if not esc_map[y][x]:
                pixels.append((0, 0, 0))
            else:
                rgb = xtc_palette(iter_map[y][x] & 0xFF)
                pixels.append(mask_6bit(rgb) if six_bit else rgb)
    im = Image.new("RGB", (W, H))
    im.putdata(pixels)
    im.save(out_path)


if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else "P189"
    poi = POIS[name]
    print(f"Sim render {name}: {poi}")
    iter_map, esc_map = sim_frame(poi["cx"], poi["cy"], poi["z"], poi["max_iter"])
    out = f'/tmp/{name.lower()}_sim.png'
    render_to_png(iter_map, esc_map, out)
    print(f"Saved {out}")
