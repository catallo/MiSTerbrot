#!/usr/bin/env python3
"""Auto-tune POI zoom levels.

For each POI, render at zoom_level + offset for offset in [-3..+3]. Score each
rendering by a heuristic that favours a 30-65% interior fraction (i.e. some
black/set-interior pixels but not entirely interior, and not entirely outside).
Among renders meeting that criterion, prefer the one with highest non-interior
color variance — i.e. richest fractal-boundary detail.

Writes the tuned list to tools/poi_master_tuned.json (does not overwrite the
original). Prints a per-POI report of original vs. tuned zoom, with rationale.
"""

import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from poi_render import render, MASTER_JSON  # reuse renderer

OUT_JSON = ROOT / "tools" / "poi_master_tuned.json"

# Search window
ZOOM_OFFSETS = [-3.0, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 3.0]

# Acceptable interior fraction (black pixels)
INTERIOR_LO = 0.03
INTERIOR_HI = 0.75


def score_image(img):
    """Return (interior_frac, detail_score)."""
    arr = np.asarray(img, dtype=np.float32)
    # interior pixels are pure black (renderer sets escaped >= max_iter to (0,0,0))
    is_interior = (arr.sum(axis=2) == 0.0)
    interior_frac = float(is_interior.mean())
    # detail score: stddev of color over non-interior pixels
    nonint = arr[~is_interior]
    if nonint.size == 0:
        detail = 0.0
    else:
        detail = float(nonint.std())
    return interior_frac, detail


def is_acceptable(interior_frac):
    return INTERIOR_LO <= interior_frac <= INTERIOR_HI


def rank_score(interior_frac, detail):
    """Higher = better.

    Penalise extreme interior fractions (outside acceptable range), reward
    detail. Aim for ~25% interior — gives a clear set-vs-outside contrast.
    """
    target = 0.25
    interior_penalty = abs(interior_frac - target) * 200.0
    if not is_acceptable(interior_frac):
        interior_penalty += 500.0
    return detail - interior_penalty


def tune_one(poi):
    cx = float(poi["cx"])
    cy = float(poi["cy"])
    base_zoom = float(poi["zoom_level"])
    candidates = []
    for off in ZOOM_OFFSETS:
        z = base_zoom + off
        if z < 0:
            continue
        if z > 30:
            continue
        img = render(cx, cy, z, w=120, h=90, max_iter=512)  # smaller for speed
        ifrac, detail = score_image(img)
        score = rank_score(ifrac, detail)
        candidates.append((z, ifrac, detail, score))

    # If anything is acceptable, pick highest score among acceptable
    acc = [c for c in candidates if is_acceptable(c[1])]
    if acc:
        best = max(acc, key=lambda c: c[3])
    else:
        best = max(candidates, key=lambda c: c[3])
    return best, candidates


def main():
    with open(MASTER_JSON) as f:
        pois = json.load(f)

    print(f"Tuning {len(pois)} POIs (offsets {ZOOM_OFFSETS})...\n")
    print(f"{'idx':>3} {'name':<22} {'orig':>6} {'tuned':>6} {'int%':>5} {'detail':>7}  note")
    print("-" * 100)

    tuned = []
    changes = 0
    for i, p in enumerate(pois):
        (z_best, ifrac_best, detail_best, _), all_cands = tune_one(p)
        orig_z = float(p["zoom_level"])
        note = ""
        if abs(z_best - orig_z) >= 0.5:
            note = f"<- changed from {orig_z}"
            changes += 1
        elif not is_acceptable(ifrac_best):
            note = "<- still bad (no acceptable zoom found)"
        tuned_p = dict(p)
        tuned_p["zoom_level"] = round(z_best, 2)
        tuned_p["zoom_level_orig"] = orig_z
        tuned.append(tuned_p)
        print(f"{i:>3} {p['name']:<22} {orig_z:>6.2f} {z_best:>6.2f} "
              f"{ifrac_best*100:>4.0f}% {detail_best:>7.1f}  {note}")

    with open(OUT_JSON, "w") as f:
        json.dump(tuned, f, indent=2)

    print(f"\n{changes} of {len(pois)} POIs had zoom adjusted.")
    print(f"Wrote {OUT_JSON}")


if __name__ == "__main__":
    main()
