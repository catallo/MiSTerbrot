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


# Threshold for "visually identical": fraction of pixels that differ
# STRUCTURALLY (one is interior, other is escaped) must be below
# DIFF_FRAC_TOL.  We deliberately ignore color-cycling differences in
# the ESCAPE colors — those don't represent iter behaviour, they
# represent palette phase.  What matters is whether each pixel was
# classified as interior (iter_count == max_iter) or escaped.
DIFF_FRAC_TOL = 0.005  # 0.5% of pixels structurally different


def interior_mask(path: Path) -> np.ndarray:
    """Return a boolean array: True where the pixel is M-set interior
    (rendered as the constant interior color — pure black across all
    90 palettes in color_mapper.v)."""
    a = np.asarray(Image.open(path).convert("RGB"))
    if a.size == 0:
        return np.zeros((0, 0), dtype=bool)
    # Pure black = interior.  All palettes map iter==max_iter (escaped=0)
    # to (0,0,0) regardless of color-cycling phase.
    is_interior = (a[:, :, 0] == 0) & (a[:, :, 1] == 0) & (a[:, :, 2] == 0)
    # Mask out the telemetry strip (top ~8 display rows × ~256 display
    # cols).  The strip contains black '0' bits which would falsely
    # count as interior.
    h, w = is_interior.shape
    mask_h = max(8, h // 60)
    mask_w = max(256, w // 2)
    is_interior[:mask_h, :mask_w] = False
    # Mask out the bottom overlay (POI name + coords + IT value).  Up to
    # ~40 display rows depending on font size.  Be generous.
    is_interior[-50:, :] = False
    # Top-right "CC: ON" / FPS counter (small region, last ~80 cols × top 8).
    is_interior[:8, -80:] = False
    return is_interior


def diff_screenshots(path_low: Path, path_ref: Path) -> float:
    """Return the fraction of pixels that are interior at `path_low` but
    NOT interior at `path_ref`.  Those are pixels where the lower
    max_iter cut off an escape that would have happened in the reference
    setting — visible quality loss.

    Cycling-friendly: only looks at interior/escaped classification,
    ignores escape-pixel colours.
    """
    low = interior_mask(path_low)
    ref = interior_mask(path_ref)
    if low.shape != ref.shape:
        return 1.0
    # "False positive interior" at low = pixel reports interior at low
    # setting but was actually escaped at ref → max_iter was too low.
    extra_interior = low & ~ref
    return float(extra_interior.mean())


# FPS tolerance: settings within this many fps of the maximum are
# considered "free" — same FPS plateau, no reason to drop iter to reach.
FPS_PLATEAU_TOL = 1.0
# Diff improvement floor: a higher-iter setting only "wins" if it cuts
# diff by more than this (absolute) over the previous best.  Anything
# tighter is measurement noise.
DIFF_IMPROVEMENT_TOL = 0.0001  # 0.01% absolute
# Visible-quality threshold: a setting whose diff is below this is
# considered "visually identical" to the reference.
ACCEPTABLE_DIFF = 0.005  # 0.5% absolute


def classify(per_setting: dict, current_auto: int,
             reference_label: str) -> tuple[str, int, str]:
    """Return (verdict, recommended_max_iter, rationale).

    Rule (user request): pick the HIGHEST iter setting at the max-fps
    plateau where each step up strictly improves diff.  If FPS is the
    same, prefer more iter — no reason to drop quality.  If the higher
    setting doesn't improve diff, no reason to go up.

    If the plateau winner still has visibly bad quality (> ACCEPTABLE_DIFF),
    escape the plateau and pick the cheapest iter that achieves
    visually-identical quality (QUALITY_FIX with explicit FPS impact).
    """
    iter_values = {"128": 128, "256": 256, "512": 512,
                   "1024": 1024, "2048": 2048,
                   "Auto": current_auto}

    fps_max = max(s["fps"] for s in per_setting.values())
    numeric = [l for l in SETTING_ORDER if l != "Auto" and l in per_setting]
    plateau = [l for l in numeric
               if per_setting[l]["fps"] >= fps_max - FPS_PLATEAU_TOL]
    if not plateau:
        plateau = numeric

    # Walk from lowest iter up; promote to higher iter only on strict
    # quality improvement (> DIFF_IMPROVEMENT_TOL).
    plateau_asc = sorted(plateau, key=lambda l: iter_values[l])
    optimal_label = plateau_asc[0]
    for lbl in plateau_asc[1:]:
        if (per_setting[lbl]["diff"] <
                per_setting[optimal_label]["diff"] - DIFF_IMPROVEMENT_TOL):
            optimal_label = lbl

    # If the plateau winner is still visibly bad, escape plateau for
    # quality — pick the lowest iter that hits ACCEPTABLE_DIFF.
    hw_limited = False
    if per_setting[optimal_label]["diff"] > ACCEPTABLE_DIFF:
        rescued = None
        for l in numeric:  # numeric is iter-ascending order
            if per_setting[l]["diff"] <= ACCEPTABLE_DIFF:
                rescued = l
                break
        if rescued is not None:
            optimal_label = rescued
        else:
            hw_limited = True  # no setting reaches acceptable

    optimal = iter_values[optimal_label]
    chosen_fps = per_setting[optimal_label]["fps"]
    chosen_diff = per_setting[optimal_label]["diff"]
    cur_fps = per_setting.get("Auto", {}).get("fps", chosen_fps)
    cur_diff = per_setting.get("Auto", {}).get("diff", 0)

    if optimal == current_auto:
        verdict = "NO_CHANGE"
        rationale = (f"Auto={current_auto} is the right setting "
                     f"({chosen_fps:.1f} fps, diff {chosen_diff*100:.2f}%).")
    elif optimal < current_auto:
        verdict = "PERF_WIN"
        delta = (chosen_fps / cur_fps - 1) * 100 if cur_fps else 0
        rationale = (f"Auto={current_auto} ({cur_fps:.1f} fps) is overkill; "
                     f"max_iter={optimal} hits {chosen_fps:.1f} fps "
                     f"({delta:+.1f}%) with diff {chosen_diff*100:.2f}%.")
    else:  # optimal > current_auto
        if cur_diff > ACCEPTABLE_DIFF:
            verdict = "QUALITY_FIX"
            rationale = (f"Auto={current_auto} has visible quality loss "
                         f"(diff {cur_diff*100:.2f}%); max_iter={optimal} "
                         f"cuts diff to {chosen_diff*100:.2f}% at "
                         f"{chosen_fps:.1f} fps (vs current {cur_fps:.1f}).")
        else:
            verdict = "QUALITY_BUMP"
            rationale = (f"Auto={current_auto} is fine ({cur_fps:.1f} fps, "
                         f"diff {cur_diff*100:.2f}%); max_iter={optimal} "
                         f"stays at fps plateau with diff "
                         f"{chosen_diff*100:.2f}% — free quality bump.")

    if hw_limited:
        rationale += " (hardware-limited: no setting reaches visually-identical quality)"
    if reference_label == "Auto" and current_auto == 4095:
        rationale += " (reference is 4095 = hardware ceiling)"

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
        # Truth from the Auto sweep telemetry (the RTL uses a per-POI
        # iter table, not just a zoom-based ladder).
        current_auto = indexed["Auto"][idx].get(
            "max_iter", auto_max_iter_for_zoom(zoom))

        # Build per-setting diff vs reference
        # Reference = the highest available setting (Auto for z≥24 → 4095,
        # otherwise 2048 since 2048 ≥ Auto for all z < 24)
        ref_label = "Auto" if current_auto >= 4095 else "2048"
        ref_path_str = indexed[ref_label][idx].get("screenshot", "")
        ref_screenshot = Path(ref_path_str) if ref_path_str else None
        if not ref_screenshot or not ref_screenshot.is_file():
            continue

        per_setting = {}
        for label in SETTING_ORDER:
            if label not in runs:
                continue
            entry = indexed[label][idx]
            shot_str = entry.get("screenshot", "")
            shot = Path(shot_str) if shot_str else None
            if not shot or not shot.is_file():
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
