#!/usr/bin/env python3
"""Automated benchmark-suite runner for the MiSTerbrot pixel telemetry.

Walks every scene defined in `tools/benchmarks.json`, waits for the F10
sliding window to fill, captures a screenshot, decodes the telemetry, and
accumulates the per-scene throughput into a JSON results file.

Assumes the core is freshly loaded (benchmark mode OFF, on scene 0). The
script starts by pressing B once to enter benchmark mode, walks scenes with V
presses, and exits benchmark mode at the end.

Usage:
    python3 tools/bench_run.py                          # full suite
    python3 tools/bench_run.py --host 10.0.0.8          # explicit host
    python3 tools/bench_run.py --output results.json    # custom output path
    python3 tools/bench_run.py --wait 12                # per-scene wait
    python3 tools/bench_run.py --scenes 0,4,7           # subset
    python3 tools/bench_run.py --label baseline         # tag the run
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_decode_screenshot import decode

ROOT = Path(__file__).resolve().parent.parent
BENCH_JSON = ROOT / "tools" / "benchmarks.json"
MISTERCLAW = ROOT / "tools" / "misterclaw-send"
DEFAULT_HOST = "10.0.0.8"
DEFAULT_WAIT = 12.0     # > 10s so the F10 window is fully populated


def send_key(host, key):
    subprocess.run(
        [str(MISTERCLAW), "--host", host, "input", "type", key],
        check=True, capture_output=True, timeout=10,
    )


def screenshot(host, out_path):
    subprocess.run(
        [str(MISTERCLAW), "--host", host, "screenshot", "--output", str(out_path)],
        check=True, capture_output=True, timeout=15,
    )


def capture_scene(host, expected_idx, tmp_dir, attempt=0):
    """Screenshot and decode, retrying once if the decoded scene index
    doesn't match what we just navigated to (slow key propagation)."""
    out = tmp_dir / f"bench_{expected_idx:02d}.png"
    screenshot(host, out)
    r = decode(out)
    if r["scene"] != expected_idx and attempt < 2:
        time.sleep(2)
        return capture_scene(host, expected_idx, tmp_dir, attempt + 1)
    return r, out


def main():
    p = argparse.ArgumentParser(description="Run the benchmark suite")
    p.add_argument("--host", default=DEFAULT_HOST,
                   help=f"MiSTer host (default {DEFAULT_HOST})")
    p.add_argument("--output", default="tools/benchmark_results.json",
                   help="Output JSON path (relative to repo root)")
    p.add_argument("--wait", type=float, default=DEFAULT_WAIT,
                   help="Seconds to wait per scene before screenshot (default 12)")
    p.add_argument("--scenes", default=None,
                   help="Comma-separated subset of scene indices (default: all)")
    p.add_argument("--label", default=None,
                   help="Label for this run (e.g., 'baseline', 'after-A1')")
    p.add_argument("--keep-screenshots", action="store_true",
                   help="Leave /tmp screenshots after the run for inspection")
    p.add_argument("--no-toggle", action="store_true",
                   help="Skip pressing B at start/end (assume bench mode already on)")
    args = p.parse_args()

    if not MISTERCLAW.exists():
        print(f"ERROR: misterclaw-send not at {MISTERCLAW}", file=sys.stderr)
        return 1
    if not BENCH_JSON.exists():
        print(f"ERROR: {BENCH_JSON} not found", file=sys.stderr)
        return 1

    with open(BENCH_JSON) as f:
        scenes = json.load(f)

    wanted = (
        set(int(s) for s in args.scenes.split(","))
        if args.scenes else set(range(len(scenes)))
    )

    tmp_dir = Path("/tmp") / f"bench_run_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    print(f"host        : {args.host}")
    print(f"scenes      : {len(wanted)} / {len(scenes)}")
    print(f"wait/scene  : {args.wait}s")
    print(f"tmp dir     : {tmp_dir}")
    print()

    if args.no_toggle:
        print(">> --no-toggle: assuming benchmark mode already on")
    else:
        print(">> Pressing B to enter benchmark mode")
        send_key(args.host, "b")
    print(f">> Waiting {args.wait:.1f}s for F10 to fill on scene 0")
    time.sleep(args.wait)

    results = []
    for idx in range(len(scenes)):
        if idx > 0:
            send_key(args.host, "v")
            time.sleep(args.wait)
        if idx not in wanted:
            continue
        scene_def = scenes[idx]
        try:
            r, png_path = capture_scene(args.host, idx, tmp_dir)
        except Exception as e:
            print(f"  [{idx:2d}] {scene_def['name']:<24}  FAILED ({e})")
            results.append({
                "idx": idx, "name": scene_def["name"], "error": str(e),
            })
            continue
        fps = r["f10"] / 10.0
        match = "" if r["scene"] == idx else f"  (!!) decoded scene={r['scene']}"
        print(f"  [{idx:2d}] {scene_def['name']:<24}  "
              f"f10={r['f10']:>4d}  fps={fps:5.1f}{match}")
        results.append({
            "idx": idx,
            "name": scene_def["name"],
            "zoom_level": scene_def.get("zoom_level"),
            "max_iter": scene_def.get("max_iter"),
            "f10": r["f10"],
            "fps": round(fps, 2),
            "decoded_scene": r["scene"],
            "decoded_iter_tier": r["iter_tier"],
            "screenshot": str(png_path),
        })

    print()
    if not args.no_toggle:
        print(">> Pressing B to exit benchmark mode")
        send_key(args.host, "b")

    out = {
        "label": args.label,
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "host": args.host,
        "wait_seconds": args.wait,
        "results": results,
    }
    out_path = Path(args.output)
    if not out_path.is_absolute():
        out_path = ROOT / out_path
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2) + "\n")
    print(f"\nWrote {len(results)} scene records to {out_path}")
    if not args.keep_screenshots:
        # Don't auto-delete; cheap to leave in /tmp and the JSON points at them.
        # Users can `rm -rf` the tmp_dir manually if they want.
        print(f"(screenshots left in {tmp_dir})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
