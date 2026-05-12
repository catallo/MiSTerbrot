#!/usr/bin/env python3
"""Deterministic FPGA vs Python compare scorer for the POI walkthrough.

Walks every `screenshots/poi_compare/idx_*/` folder and compares the FPGA
capture (`fpga.png`) against the Python reference (`python.png`) using two
palette-independent metrics:

  - **Interior-fraction delta**: |frac_interior(fpga) - frac_interior(python)|.
    Set-interior pixels are pure RGB(0,0,0) in both renderers, so we can pick
    them out without caring about palette or colour cycling.

  - **Interior-mask IoU**: intersection-over-union of the two interior masks.
    Catches coordinate / zoom-level mismatches where the fractal *boundary*
    sits in a different place between FPGA and Python even when the overall
    "amount of black" matches.

Composite score = IoU - frac_delta (range roughly -1..+1, higher = better
agreement). Output is sorted worst-first so you can focus visual review on
the top 5-10 likely-divergent POIs.

Flags surfaced on each row:
  BOTH_SOLID  — both renders are >95% interior (probably over-zoomed into
                a bulb / nucleus; the IoU will be misleadingly perfect)
  FRAC_DELTA  — interior fraction differs by > 30% between FPGA and Python
                (typically: one side ran out of iterations and went all-black,
                 or POI framing differs significantly)
  LOW_IOU     — IoU < 0.5 (interior masks barely overlap — coord/zoom error)

Usage:
  python3 tools/poi_compare_score.py
  python3 tools/poi_compare_score.py --top 10        # print only top 10 worst
  python3 tools/poi_compare_score.py --json out.json # also dump full results

Limits:
  - Does not catch palette-bound differences (escaped-pixel artefacts,
    cycling-phase shifts, banding patterns where interior masks happen
    to match). For those, fall back to eyeballing compare.png.
  - Resizes FPGA captures from 640x480 (HDMI output) down to 640x240 so
    the masks compare 1:1 against the native Python thumbnails.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
COMPARE_DIR = ROOT / "screenshots" / "poi_compare"
TARGET_SIZE = (640, 240)


def interior_mask(img_path):
    """Return a (H, W) boolean mask of set-interior pixels (R+G+B == 0)."""
    img = Image.open(img_path).convert("RGB")
    if img.size != TARGET_SIZE:
        img = img.resize(TARGET_SIZE, Image.BILINEAR)
    arr = np.asarray(img, dtype=np.int32)
    return arr.sum(axis=2) == 0


def score_pair(fpga_path, py_path):
    """Score a single pair.

    Returns a dict with frac/IoU stats and a composite score in roughly
    [-1, +1] where higher = better agreement. The composite weights frac_delta
    heavily and only counts IoU when one side has substantial interior — that
    way deep-boundary POIs (both ~0% interior) don't get false LOW_IOU flags
    just because their tiny masks happen not to overlap pixel-perfectly.
    """
    m_fpga = interior_mask(fpga_path)
    m_py = interior_mask(py_path)
    fpga_frac = float(m_fpga.mean())
    py_frac = float(m_py.mean())
    frac_delta = abs(fpga_frac - py_frac)
    intersection = int((m_fpga & m_py).sum())
    union = int((m_fpga | m_py).sum())
    iou = (intersection / union) if union > 0 else 1.0
    # Only trust IoU when interior actually exists on at least one side
    # (>=5% covers minibrots, bulbs, deep-interior framings).
    iou_meaningful = max(fpga_frac, py_frac) >= 0.05
    if iou_meaningful:
        score = iou - frac_delta
    else:
        score = -frac_delta   # purely frac-delta based; both sides ~exterior
    return {
        "fpga_frac": fpga_frac,
        "py_frac": py_frac,
        "frac_delta": frac_delta,
        "iou": iou,
        "iou_meaningful": iou_meaningful,
        "score": score,
        "both_solid": fpga_frac > 0.95 and py_frac > 0.95,
    }


def main():
    parser = argparse.ArgumentParser(description="Score FPGA-vs-Python compare pairs.")
    parser.add_argument("--top", type=int, default=0,
                        help="Print only the top N worst-scoring pairs (default: all)")
    parser.add_argument("--json", type=str, default=None,
                        help="Also dump full results to this JSON file")
    args = parser.parse_args()

    if not COMPARE_DIR.exists():
        print(f"ERROR: {COMPARE_DIR} not found. Run tools/poi_walkthrough.py first.",
              file=sys.stderr)
        sys.exit(1)

    results = []
    for folder in sorted(COMPARE_DIR.iterdir()):
        if not folder.is_dir() or folder.name.startswith("_"):
            continue
        fpga = folder / "fpga.png"
        py = folder / "python.png"
        if not (fpga.exists() and py.exists()):
            continue
        try:
            r = score_pair(fpga, py)
        except Exception as e:
            print(f"  WARN: {folder.name}: {e}", file=sys.stderr)
            continue
        r["folder"] = folder.name
        results.append(r)

    results.sort(key=lambda r: r["score"])  # worst first
    to_show = results[:args.top] if args.top > 0 else results

    print(f"# POI compare scoring — {len(results)} pairs, worst-first")
    print(f"# {'folder':<46}  {'fpga%':>6} {'py%':>6} {'dfrac%':>7} {'IoU':>5}  {'score':>6}  flags")
    for r in to_show:
        flags = []
        if r["both_solid"]:
            flags.append("BOTH_SOLID")
        if r["frac_delta"] > 0.10:
            flags.append("FRAC_DELTA")
        if r["iou_meaningful"] and r["iou"] < 0.50:
            flags.append("LOW_IOU")
        flag_str = ",".join(flags) if flags else ""
        print(f"  {r['folder']:<46}  "
              f"{r['fpga_frac']*100:5.1f}% {r['py_frac']*100:5.1f}% "
              f"{r['frac_delta']*100:6.1f}% {r['iou']:5.3f}  {r['score']:+5.3f}  "
              f"{flag_str}")

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2))
        print(f"\n# Full results written to {args.json}", file=sys.stderr)


if __name__ == "__main__":
    main()
