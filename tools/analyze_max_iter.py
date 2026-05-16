#!/usr/bin/env python3
"""Analyze the per-POI max_iter sweep and recommend optimal values.

Inputs: the 6 JSON files produced by `tools/profile_max_iter.py`
(one per iter setting: Auto/128/256/512/1024/2048).

For each POI, the script:
  1. Picks a REFERENCE setting (highest available: 2048, or Auto if Auto
     resolves to 4095 for that POI).
  2. Diffs each setting's screenshot vs the reference.
  3. Recommends the smallest setting whose screenshot is visually
     indistinguishable from the reference (pixel diff under a threshold).
  4. Classifies each POI as PERF_WIN, NO_CHANGE, QUALITY_FIX, or
     HARDWARE_LIMIT.

Output:
  - Per-POI report on stdout (human-readable)
  - JSON report at tools/profile_iter_report.json
  - Suggested catalogue edits printed at the end for review
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

# Order matters: lower → higher iter
SETTING_ORDER = ["128", "256", "512", "1024", "2048", "Auto"]

# Map "Auto" string to the actual max_iter the zoom-tier ladder picks
# (mirror of fractal_top.v:336):
#   z<12: 512, 12≤z<18: 1024, 18≤z<24: 2048, z≥24: 4095
def auto_max_iter_for_zoom(z: float) -> int:
    if z < 12:  return 512
    if z < 18:  return 1024
    if z < 24:  return 2048
    return 4095


# Threshold for "visually identical": fraction of pixels that differ by
# more than COLOR_TOL (per channel) must be below DIFF_FRAC_TOL.
COLOR_TOL = 16   # 0-255 per channel
DIFF_FRAC_TOL = 0.001  # 0.1% of pixels


def diff_screenshots(path_a: Path, path_b: Path) -> float:
    """Return the fraction of pixels that differ by >COLOR_TOL per channel."""
    a = np.asarray(Image.open(path_a).convert("RGB"), dtype=np.int16)
    b = np.asarray(Image.open(path_b).convert("RGB"), dtype=np.int16)
    if a.shape != b.shape:
        return 1.0
    # crop the telemetry strip (top 4 native rows × 128 native px wide
    # = top 8 display rows × 256 display px wide for 2× capture).
    # Telemetry differs by iter_tier between sweeps — exclude it.
    h, w = a.shape[:2]
    mask_h = max(8, h // 60)   # ~8 px at 480-tall capture
    mask_w = max(256, w // 2)  # leftmost ~256 px
    a[:mask_h, :mask_w] = 0
    b[:mask_h, :mask_w] = 0
    # Also exclude the bottom overlay region (last ~30 display rows).
    # The overlay shows "IT: NNNN" which differs between sweeps.
    a[-30:, :] = 0
    b[-30:, :] = 0

    diff = np.any(np.abs(a - b) > COLOR_TOL, axis=2)
    return float(diff.mean())


def classify(per_setting: dict, current_auto: int,
             reference_label: str) -> tuple[str, int, str]:
    """Return (verdict, recommended_max_iter, rationale)."""
    ref = per_setting[reference_label]
    ref_diff_zero = True  # by definition

    # Find smallest setting whose diff ≤ tolerance
    iter_values = {"128": 128, "256": 256, "512": 512,
                   "1024": 1024, "2048": 2048,
                   "Auto": current_auto}
    optimal_label = reference_label
    for label in SETTING_ORDER:
        if label not in per_setting:
            continue
        if per_setting[label]["diff"] <= DIFF_FRAC_TOL:
            optimal_label = label
            break

    optimal = iter_values[optimal_label]
    # Resolve "Auto" -> integer for output
    if optimal_label == "Auto":
        optimal = current_auto

    # Decide verdict
    if optimal == current_auto:
        verdict = "NO_CHANGE"
        rationale = f"Current Auto={current_auto} is already optimal."
    elif optimal < current_auto:
        verdict = "PERF_WIN"
        ref_f10 = per_setting[reference_label]["f10"]
        new_f10 = per_setting[optimal_label]["f10"]
        improve = (new_f10 / ref_f10 - 1) * 100 if ref_f10 else 0
        rationale = (f"Current Auto={current_auto} is overkill; "
                     f"max_iter={optimal} produces visually identical "
                     f"image at F10 {ref_f10}→{new_f10} ({improve:+.1f}%).")
    else:  # optimal > current_auto
        verdict = "QUALITY_FIX"
        cur_diff = per_setting.get("Auto", {}).get("diff", 0)
        rationale = (f"Current Auto={current_auto} is insufficient — "
                     f"diff {cur_diff*100:.2f}% vs reference (max_iter={iter_values[reference_label]}). "
                     f"Need max_iter={optimal}.")

    # Hardware limit: reference is 4095 (Auto for deep zoom) AND ref
    # itself differs from a higher hypothetical reference — we can't
    # measure that, but flag for review.
    # (No detection here; just note in rationale if reference is 4095.)
    if reference_label == "Auto" and current_auto == 4095:
        rationale += " (Reference is 4095 = hardware ceiling.)"

    return verdict, optimal, rationale


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("jsons", nargs="+", help="Profile JSON files (one per iter setting)")
    p.add_argument("--report",
                   default=str(ROOT / "tools" / "profile_iter_report.json"))
    args = p.parse_args()

    # Load all bench sweeps; key by setting label parsed from filename
    runs = {}
    for path in args.jsons:
        p = Path(path)
        data = json.loads(p.read_text())
        label = data.get("label", p.stem).replace("profile-iter-", "")
        if label not in SETTING_ORDER:
            print(f"WARN: unknown label {label!r} in {path}", file=sys.stderr)
            continue
        runs[label] = data

    if "Auto" not in runs:
        print("ERROR: Auto sweep missing — needed as reference for deep-zoom POIs.",
              file=sys.stderr)
        return 1
    if "2048" not in runs:
        print("ERROR: 2048 sweep missing — needed as reference for non-deep POIs.",
              file=sys.stderr)
        return 1

    # Build per-POI table
    catalogue = json.loads((ROOT / "tools" / "poi_master.json").read_text())
    by_name = {p["name"]: p for p in catalogue}

    # Each sweep's results: list of {idx, name, f10, screenshot, ...}
    # Index by (label, idx)
    indexed = {label: {r["idx"]: r for r in data["results"]}
               for label, data in runs.items()}

    n_pois = max(len(d["results"]) for d in runs.values())
    report = []
    for idx in range(n_pois):
        # All settings must have this idx
        if not all(idx in indexed[lbl] for lbl in runs):
            continue
        name = indexed["Auto"][idx]["name"]
        poi = by_name.get(name, {})
        zoom = poi.get("zoom_level", 0)
        current_auto = auto_max_iter_for_zoom(zoom)

        # Build per-setting diff vs reference
        # Reference = the highest available setting (Auto for z≥24 → 4095,
        # otherwise 2048 since 2048 ≥ Auto for all z < 24)
        ref_label = "Auto" if current_auto >= 4095 else "2048"
        ref_screenshot = Path(indexed[ref_label][idx].get("screenshot", ""))
        if not ref_screenshot.exists():
            continue

        per_setting = {}
        for label in SETTING_ORDER:
            if label not in runs:
                continue
            entry = indexed[label][idx]
            shot = Path(entry.get("screenshot", ""))
            if not shot.exists():
                continue
            d = diff_screenshots(shot, ref_screenshot)
            per_setting[label] = {
                "diff": d,
                "f10": entry["f10"],
                "fps": entry["f10"] / 10.0,
            }

        verdict, rec_max, rationale = classify(
            per_setting, current_auto, ref_label)

        report.append({
            "idx": idx,
            "name": name,
            "zoom_level": zoom,
            "current_auto_max_iter": current_auto,
            "reference_label": ref_label,
            "per_setting": per_setting,
            "verdict": verdict,
            "recommended_max_iter": rec_max,
            "rationale": rationale,
        })

    # Print + save
    print(f"{'#':>3}  {'POI':<25}  {'cur':>5}  {'rec':>5}  verdict       diff per setting (% pixels)")
    print("-" * 110)
    for r in report:
        ds = "  ".join(
            f"{lbl}:{r['per_setting'][lbl]['diff']*100:5.2f}%"
            for lbl in SETTING_ORDER if lbl in r["per_setting"]
        )
        print(f"{r['idx']:>3}  {r['name']:<25}  {r['current_auto_max_iter']:>5}  "
              f"{r['recommended_max_iter']:>5}  {r['verdict']:<13}  {ds}")

    # Bucket summary
    verdicts = {}
    for r in report:
        verdicts.setdefault(r["verdict"], []).append(r["name"])
    print()
    for v, names in verdicts.items():
        print(f"{v}: {len(names)} POIs")
        if v in ("PERF_WIN", "QUALITY_FIX"):
            for n in names:
                print(f"  - {n}")

    # Save JSON
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n")
    print(f"\nReport saved: {args.report}")

    # Suggested catalogue edits
    print("\n--- Suggested poi_master.json edits ---")
    for r in report:
        if r["verdict"] != "NO_CHANGE":
            print(f'  "{r["name"]}": add  "max_iter": {r["recommended_max_iter"]}  '
                  f'  // {r["verdict"]}: {r["rationale"]}')

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
