#!/usr/bin/env python3
"""Flag POIs whose thumbnail is all-interior, all-exterior, or otherwise dead.

Reads tools/poi_master.json and screenshots/poi/idx_NNN_*.png. Prints a list
of indexes that need attention, with a 1-line reason each.
"""
import json
import re
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
THUMB_DIR = ROOT / "screenshots" / "poi"


def safe_filename(name):
    s = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower()
    return s or "unnamed"


def main():
    with open(MASTER_JSON) as f:
        pois = json.load(f)

    print(f"{'idx':>3} {'name':<22} {'int%':>5} {'ext%':>5} {'std':>6}  status")
    print("-" * 70)
    bad = []
    for i, p in enumerate(pois):
        fname = THUMB_DIR / f"idx_{i:03d}_{safe_filename(p['name'])}.png"
        if not fname.exists():
            print(f"{i:>3} {p['name']:<22}  --   --     --   missing thumbnail")
            continue
        arr = np.asarray(Image.open(fname), dtype=np.float32)
        sum_rgb = arr.sum(axis=2)
        is_interior = (sum_rgb == 0.0)
        is_exterior_min = (arr.min(axis=2) > 200) & (arr.max(axis=2) - arr.min(axis=2) < 50)
        ifrac = float(is_interior.mean())
        efrac = float(is_exterior_min.mean())
        std = float(arr.std())

        status = "ok"
        if ifrac > 0.95:
            status = "ALL-BLACK (interior)"
            bad.append(i)
        elif efrac > 0.95:
            status = "ALL-FLAT (single color)"
            bad.append(i)
        elif ifrac > 0.85:
            status = "mostly-interior"
            bad.append(i)
        elif std < 30:
            status = "low-detail"
            bad.append(i)
        elif ifrac < 0.005:
            status = "no-set-visible"
            bad.append(i)

        print(f"{i:>3} {p['name']:<22} {ifrac*100:>4.0f}% {efrac*100:>4.0f}% {std:>6.1f}  {status}")

    print(f"\n{len(bad)} flagged: {bad}")


if __name__ == "__main__":
    main()
