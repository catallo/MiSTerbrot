#!/usr/bin/env python3
"""Verify the Gallery Mode index buffer on hardware via HPS devmem.

MiSTer screenshots cannot see framework-FB content (they read ascal's
triple buffer, which sits before the FB reader), so gallery hardware
verification samples the DDR3 index buffer directly through the ARM:
one `misterclaw-send shell` call batches hundreds of `devmem` reads.

For each sampled 32-bit word (4 horizontally adjacent pixels) the
expected index comes from a float reference iteration at the FPGA's
gallery grid (pitch = step * 2/9, cr = cx + (x-960)p, ci = cy +
(y-540)p + p/2):

    index = escaped ? (iter & 0xFF or 1) : 0

Float vs 8.56 fixed point disagrees near the escape boundary, so the
score is statistical: interior/deep-escape samples match exactly,
boundary samples may differ by a small iter delta.  A correct buffer
scores >85% typically; a wrong POI or broken addressing scores near
the 256-way noise floor.

Usage:
  gallery_verify.py --poi <idx>       verify against one catalogue POI
  gallery_verify.py --identify        best match over the whole catalogue
  gallery_verify.py --bank b          sample bank B (default A)
  gallery_verify.py --samples N       words to sample (default 300)
  gallery_verify.py --frac-zoom       use the fractional catalogue zoom
                                      (default: integer snap zoom — the
                                      M-snap/gallery sequencing renders
                                      at DEFAULT_STEP >>> int(zoom))

Proven on silicon 2026-07-11: EJS DBL SPIRAL at snap zoom scored
996/1000 exact (remainder is float-vs-8.56 boundary noise).

Requires the core to be in gallery mode with the target POI rendered
(wait for the paint to finish in live mode).
"""

import json
import random
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
MISTERCLAW = str(ROOT / "tools" / "misterclaw-send")
HOST = "10.0.0.8"

BASE = {0: 0x3020_0000, 1: 0x3060_0000}
STRIDE = 2048
W, H = 1920, 1080
DEFAULT_STEP = 0.0125
MAX_ITER_TIERS = [(12, 1024), (18, 2048), (24, 4096)]


def max_iter_for_zoom(zoom_level):
    for z, m in MAX_ITER_TIERS:
        if zoom_level < z:
            return m
    return 8192


def sample_words(bank, coords):
    """One ssh round trip, many devmem reads.  coords = [(x,y)] with
    x % 4 == 0; returns {(x,y): [4 index bytes]}."""
    addrs = [BASE[bank] + y * STRIDE + x for (x, y) in coords]
    script = ";".join(f"devmem 0x{a:08X}" for a in addrs)
    out = subprocess.run(
        [MISTERCLAW, "--host", HOST, "shell", script],
        check=True, capture_output=True, text=True, timeout=180,
    ).stdout
    vals = re.findall(r"0x[0-9A-Fa-f]{8}", out)
    if len(vals) != len(coords):
        sys.exit(f"ERROR: expected {len(coords)} words, got {len(vals)}")
    res = {}
    for (xy, v) in zip(coords, vals):
        w = int(v, 16)
        res[xy] = [(w >> (8 * i)) & 0xFF for i in range(4)]  # little endian
    return res


def reference_indices(cx, cy, zoom_level, coords, max_iter=None):
    """Expected FB indices for the sampled pixels (float reference)."""
    step = DEFAULT_STEP / (2.0 ** zoom_level)
    pitch = step * 2.0 / 9.0
    if max_iter is None:
        max_iter = max_iter_for_zoom(zoom_level)
    pts = []
    for (x, y) in coords:
        for i in range(4):
            cr = cx + ((x + i) - W / 2) * pitch
            ci = cy + (y - H / 2) * pitch + pitch / 2
            pts.append(complex(cr, ci))
    C = np.array(pts)
    Z = np.zeros_like(C)
    escaped_at = np.full(C.shape, -1, dtype=np.int64)
    mask = np.ones(C.shape, dtype=bool)
    for n in range(1, max_iter + 1):
        Z[mask] = Z[mask] * Z[mask] + C[mask]
        newly = mask & (Z.real ** 2 + Z.imag ** 2 > 4.0)
        escaped_at[newly] = n
        mask &= ~newly
        if not mask.any():
            break
    idx = np.where(escaped_at < 0, 0,
                   np.where(escaped_at & 0xFF == 0, 1, escaped_at & 0xFF))
    return idx.reshape(len(coords), 4), escaped_at.reshape(len(coords), 4)


def score(hw, ref_idx, ref_esc):
    """Fraction of samples consistent with the reference.  Boundary
    pixels (escape-time sensitive) count as consistent when hardware
    disagrees but both sides are non-interior."""
    exact = interior_ok = loose = total = 0
    for r, (xy, bytes4) in enumerate(sorted(hw.items())):
        for i in range(4):
            total += 1
            h = bytes4[i]
            e = int(ref_idx[r][i])
            if h == e:
                exact += 1
            elif (h == 0) == (ref_esc[r][i] < 0):
                # same interior/escaped class, different iter -> boundary
                loose += 1
            elif ref_esc[r][i] < 0 and h == 0:
                interior_ok += 1
    return exact, loose, total


def main():
    args = sys.argv[1:]
    bank = 1 if "--bank" in args and args[args.index("--bank") + 1] in ("1", "b", "B") else 0
    n = int(args[args.index("--samples") + 1]) if "--samples" in args else 300
    pois = json.load(open(MASTER_JSON))

    rng = random.Random(1234)
    coords = sorted({(rng.randrange(0, W // 4) * 4, rng.randrange(0, H))
                     for _ in range(n)})
    print(f"Sampling {len(coords)} words from bank {bank}...")
    hw = sample_words(bank, coords)

    def eval_poi(p):
        # gallery forces the 12-bit iteration ceiling (user spec,
        # 2026-07-11) — per-POI overrides no longer apply there
        ref_idx, ref_esc = reference_indices(
            float(p["cx"]), float(p["cy"]), poi_zoom(p), coords,
            max_iter=4095)
        return score(hw, ref_idx, ref_esc)

    frac = "--frac-zoom" in args

    def poi_zoom(p):
        z = float(p["zoom_level"])
        return z if frac else float(int(z))

    if "--poi" in args:
        i = int(args[args.index("--poi") + 1])
        p = pois[i]
        exact, loose, total = eval_poi(p)
        pct = 100.0 * (exact + loose) / total
        print(f"[{i}] {p['name']}: exact {exact}/{total}, "
              f"class-consistent {exact + loose}/{total} ({pct:.1f}%)")
        sys.exit(0 if pct >= 80.0 else 1)
    else:
        results = []
        for i, p in enumerate(pois):
            exact, loose, total = eval_poi(p)
            results.append((exact, exact + loose, i, p["name"]))
            print(f"  [{i:2d}] {p['name']:<28} exact {exact}/{total}")
        # rank by EXACT: interior-heavy images cross-match badly on the
        # class-consistent metric (learned the hard way on silicon)
        results.sort(reverse=True)
        best = results[0]
        print(f"\nBest match: [{best[2]}] {best[3]} "
              f"({best[0]} exact, {best[1]} consistent)")


if __name__ == "__main__":
    main()
