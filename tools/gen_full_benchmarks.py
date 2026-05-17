#!/usr/bin/env python3
"""Generate benchmarks.json covering every POI in poi_master.json.

The benchmark scene table is compiled into the FPGA (see
tools/bench_encode.py → rtl/benchmark_generated.vh), so the order here
fixes the runtime scene_idx mapping.

Each POI is assigned max_iter from the same zoom_level → tier mapping the
runtime Auto-iter uses, and a palette is rotated through the 90-palette
catalogue so adjacent scenes don't repeat colour.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POI_PATH = ROOT / "tools" / "poi_master.json"
OUT_PATH = ROOT / "tools" / "benchmarks.json"

N_PALETTES = 90


def max_iter_for_zoom(z):
    # Mirrors the Auto-iter thresholds in fractal_top.v
    if z < 6:   return 512
    if z < 12:  return 1024
    if z < 18:  return 2048
    return 4095


def main():
    pois = json.loads(POI_PATH.read_text())

    scenes = []
    for idx, p in enumerate(pois):
        palette = (idx * 7) % N_PALETTES  # Spread palettes; coprime with 90
        # Per-POI max_iter override takes precedence over the zoom-tier
        # ladder.  Source: tools/analyze_max_iter.py recommendations.
        mi = p.get("max_iter", max_iter_for_zoom(p["zoom_level"]))
        scenes.append({
            "name": p["name"],
            "cx": p["cx"],
            "cy": p["cy"],
            "zoom_level": p["zoom_level"],
            "max_iter": mi,
            "mode_640": True,
            "palette": palette,
            # A3 per-POI opt-in: enable period-3 bulb precheck only for POIs
            # that actually live near a period-3 bulb. Defaults False so
            # unrelated POIs don't pay the ~12-cycle-per-pixel S_BULB3
            # overhead.
            "precheck_p3": p.get("precheck_p3", False),
            "note": p.get("note", ""),
        })

    OUT_PATH.write_text(json.dumps(scenes, indent=2) + "\n")
    print(f"Wrote {len(scenes)} scenes to {OUT_PATH}")


if __name__ == "__main__":
    main()
