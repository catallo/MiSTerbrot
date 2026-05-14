#!/usr/bin/env python3
"""Full Track A sweep: 86 POIs × 5 (MS, MR) conditions = 430 measurements.

Conditions:
  1. MS off            (MR irrelevant when MS is off)
  2. MS on + MR = 16
  3. MS on + MR = 32
  4. MS on + MR = 64
  5. MS on + MR = 128

For each condition: reload the core (resets all sticky key overrides), press
S/A to set MS, optionally press 1/2/3/4 to set MR, then invoke bench_run.py
to walk the 86 scenes. Each condition takes ~18 minutes; total ~95 min.

Output: one JSON per condition in tools/benchmark_results_full/.

Usage:
    tools/bench_run_full.py
    tools/bench_run_full.py --host 10.0.0.8
    tools/bench_run_full.py --conditions ms-off,ms-on-mr16   # subset
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MISTERCLAW = ROOT / "tools" / "misterclaw-send"
BENCH_RUN = ROOT / "tools" / "bench_run.py"
DEFAULT_HOST = "10.0.0.8"
RBF_PATH = "/media/fat/_Other/MiSTerbrot_20260514.rbf"

# (label, ms_key, mr_key)  —  ms_key sets MS via S/A; mr_key (or None) sets MR via 1/2/3/4
CONDITIONS = [
    ("ms-off",       "A", None),
    ("ms-on-mr16",   "S", "1"),
    ("ms-on-mr32",   "S", "2"),
    ("ms-on-mr64",   "S", "3"),
    ("ms-on-mr128",  "S", "4"),
]


def reload_core(host):
    subprocess.run(
        ["sshpass", "-p", "1", "ssh",
         "-o", "StrictHostKeyChecking=accept-new",
         f"root@{host}",
         f"echo 'load_core {RBF_PATH}' > /dev/MiSTer_cmd"],
        check=True, capture_output=True, timeout=15,
    )
    time.sleep(6)  # let the core fully reload


def send_key(host, key):
    subprocess.run(
        [str(MISTERCLAW), "--host", host, "--timeout", "30",
         "input", "type", key],
        check=True, capture_output=True, timeout=15,
    )
    time.sleep(0.5)


def run_condition(host, label, ms_key, mr_key, wait, out_dir):
    print(f"\n========== {label} ==========")
    print(f">> Reloading core")
    reload_core(host)
    print(f">> Setting MS via key '{ms_key}'")
    send_key(host, ms_key)
    if mr_key is not None:
        print(f">> Setting MR via key '{mr_key}'")
        send_key(host, mr_key)
    out_path = out_dir / f"benchmark_results_{label}.json"
    print(f">> bench_run.py → {out_path}")
    rc = subprocess.run(
        [sys.executable, str(BENCH_RUN),
         "--host", host,
         "--output", str(out_path),
         "--label", label,
         "--wait", str(wait)],
        check=False,
    )
    if rc.returncode != 0:
        print(f"!! bench_run.py for {label} failed (rc={rc.returncode})",
              file=sys.stderr)
    return rc.returncode == 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default=DEFAULT_HOST)
    p.add_argument("--wait", type=float, default=12.0,
                   help="bench_run --wait per scene (default 12)")
    p.add_argument("--out-dir", default="tools/benchmark_results_full",
                   help="Output directory for per-condition JSONs")
    p.add_argument("--conditions", default=None,
                   help="Comma-separated labels to run (default: all 5)")
    args = p.parse_args()

    out_dir = Path(args.out_dir)
    if not out_dir.is_absolute():
        out_dir = ROOT / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    wanted_labels = (
        set(args.conditions.split(",")) if args.conditions
        else {c[0] for c in CONDITIONS}
    )
    conditions = [c for c in CONDITIONS if c[0] in wanted_labels]

    print(f"Running {len(conditions)} condition(s) × 86 scenes  ≈ "
          f"{len(conditions) * 86 * args.wait / 60:.0f} min")
    print(f"Out: {out_dir}")

    results = {}
    for label, ms_key, mr_key in conditions:
        ok = run_condition(args.host, label, ms_key, mr_key, args.wait, out_dir)
        results[label] = "ok" if ok else "FAILED"

    print("\n\n========== SUMMARY ==========")
    for label, status in results.items():
        print(f"  {label:<14s} {status}")
    return 0 if all(s == "ok" for s in results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
