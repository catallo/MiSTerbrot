#!/usr/bin/env python3
"""Per-POI max_iter profiler.

For each of 6 iter settings (Auto / 128 / 256 / 512 / 1024 / 2048),
runs the full 90-POI benchmark sweep and saves the results + screenshots.

The OSD-driven iter setting overrides the per-scene bench_max_iter
when not Auto (see fractal_top.v line ~325).  After core reload the
default is Auto, so we cycle the iter setting via repeated `I` key
presses before each sweep.

I-key cycle (rtl/input_handler.v line 220-223):
    5 (Auto) -> 0 (128) -> 1 (256) -> 2 (512) -> 3 (1024) -> 4 (2048) -> wrap

After reload iter_sel resets to Auto (5).  So:
    0 presses = Auto
    1 press   = 128
    2 presses = 256
    3 presses = 512
    4 presses = 1024
    5 presses = 2048

Run from project root.  Takes ~110 min for 6 sweeps × ~18 min each.
Output goes to tools/benchmark_results_profile_iter/iter_{label}.json
plus screenshots preserved in /tmp/bench_run_*.

Then run `tools/analyze_max_iter.py` to generate the per-POI
recommendation report.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MISTERCLAW = ROOT / "tools" / "misterclaw-send"
BENCH_RUN = ROOT / "tools" / "bench_run.py"

# (label, presses-from-Auto-default)
ITER_SETTINGS = [
    ("Auto", 0),
    ("128",  1),
    ("256",  2),
    ("512",  3),
    ("1024", 4),
    ("2048", 5),
]


def send_key(host: str, key: str) -> None:
    subprocess.run(
        [str(MISTERCLAW), "--host", host, "--timeout", "30",
         "input", "type", key],
        check=True, capture_output=True, timeout=15,
    )


def reload_core(host: str, rbf: str) -> None:
    subprocess.run(
        ["sshpass", "-p", "1", "ssh",
         "-o", "StrictHostKeyChecking=accept-new",
         f"root@{host}",
         f"echo 'load_core /media/fat/_Other/{rbf}' > /dev/MiSTer_cmd"],
        check=True, timeout=30,
    )


def sweep_one(host: str, rbf: str, label: str, n_presses: int,
              out_dir: Path, screenshots_root: Path) -> Path:
    """Reload, set iter, run bench, return path to JSON."""
    print(f"\n{'='*60}")
    print(f"Sweep with iter setting: {label}  ({n_presses} I-presses)")
    print(f"{'='*60}")

    reload_core(host, rbf)
    time.sleep(5)  # core must finish loading

    # G + L per the verification-keys memory rule (dim BG + disable auto-hide)
    send_key(host, "g")
    send_key(host, "l")

    # Cycle iter setting to the desired tier.
    if n_presses > 0:
        print(f"  pressing I {n_presses} time(s) to reach {label}...")
        for _ in range(n_presses):
            send_key(host, "i")
            time.sleep(0.3)
        time.sleep(1)  # settle

    # Run the bench sweep — screenshots go into a per-setting subdir
    # under the timestamped profile root so they survive /tmp wipes
    # and the analyzer can find them later.
    out_json = out_dir / f"iter_{label}.json"
    shots_dir = screenshots_root / f"iter_{label}"
    print(f"  bench sweep → {out_json}")
    print(f"  screenshots → {shots_dir}")
    cmd = ["python3", str(BENCH_RUN),
           "--host", host,
           "--label", f"profile-iter-{label}",
           "--output", str(out_json),
           "--screenshots-dir", str(shots_dir),
           "--keep-screenshots"]
    subprocess.run(cmd, check=True)
    return out_json


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="10.0.0.8")
    p.add_argument("--rbf",
                   default=f"MiSTerbrot_{datetime.now().strftime('%Y%m%d')}.rbf")
    p.add_argument("--out-dir",
                   default=str(ROOT / "tools" / "benchmark_results_profile_iter"))
    p.add_argument("--settings",
                   help="Comma-separated subset of {Auto,128,256,512,1024,2048}. "
                        "Default: all six.")
    args = p.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Timestamped screenshots root inside the repo so the data survives
    # /tmp wipes and is browsable after the sweep.  One subdir per
    # iter setting under this root.
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    screenshots_root = ROOT / "screenshots" / f"bench_iter_profile_{ts}"
    screenshots_root.mkdir(parents=True, exist_ok=True)

    requested = set(args.settings.split(",")) if args.settings else None
    settings = [s for s in ITER_SETTINGS if (requested is None or s[0] in requested)]
    if not settings:
        print(f"ERROR: no matching iter settings in {requested}",
              file=sys.stderr)
        return 1

    print(f"Profiling {len(settings)} iter setting(s) on {args.host}")
    print(f"RBF: {args.rbf}")
    print(f"Output dir:        {out_dir}")
    print(f"Screenshots root:  {screenshots_root}")
    print(f"Estimated runtime: {len(settings) * 18} min")

    written = []
    for label, n_presses in settings:
        path = sweep_one(args.host, args.rbf, label, n_presses,
                         out_dir, screenshots_root)
        written.append((label, path))

    print(f"\n{'='*60}")
    print("All sweeps complete.")
    for label, path in written:
        print(f"  iter={label:>5}  →  {path}")
    print(f"\nNext: python3 tools/analyze_max_iter.py {' '.join(str(p) for _, p in written)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
