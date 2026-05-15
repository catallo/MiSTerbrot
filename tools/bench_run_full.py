#!/usr/bin/env python3
"""Multi-condition Track A sweep driver.

For each (label, key_sequence) entry in CONDITIONS, reload the core, send
the keys to set up the configuration, then invoke bench_run.py to walk the
86 scenes. One JSON per condition lands in tools/benchmark_results_full/.

Currently a single condition: MS off (Mariani-Silver dropped from the
shipping core — see docs/MR16_HANG_REPORT_V2.md). Add new conditions to
CONDITIONS as future features land:

  ("label",  ["key1", "key2", ...])

Usage:
    tools/bench_run_full.py
    tools/bench_run_full.py --host 10.0.0.8
    tools/bench_run_full.py --rbf MiSTerbrot_20260516.rbf
    tools/bench_run_full.py --conditions ms-off
"""

import argparse
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MISTERCLAW = ROOT / "tools" / "misterclaw-send"
BENCH_RUN = ROOT / "tools" / "bench_run.py"
DEFAULT_HOST = "10.0.0.8"
DEFAULT_RBF = "MiSTerbrot_" + datetime.now().strftime("%Y%m%d") + ".rbf"

# (label, key_sequence) — keys are sent in order between core reload and
# bench_run.py invocation. Empty list = run with default config.
CONDITIONS = [
    ("ms-off",  []),
    # Future examples (add when supported):
    # ("ms-on",   ["S"]),
    # ("ms-on-mr64", ["S", "3"]),
    # ("palette-fire", ["P", "P"]),  # whatever
]


def reload_core(host, rbf):
    subprocess.run(
        ["sshpass", "-p", "1", "ssh",
         "-o", "StrictHostKeyChecking=accept-new",
         f"root@{host}",
         f"echo 'load_core /media/fat/_Other/{rbf}' > /dev/MiSTer_cmd"],
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


def run_condition(host, rbf, label, keys, wait, out_dir):
    print(f"\n========== {label} ==========")
    print(f">> Reloading core ({rbf})")
    reload_core(host, rbf)
    for key in keys:
        print(f">> Sending key '{key}'")
        send_key(host, key)
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
    p.add_argument("--rbf", default=DEFAULT_RBF,
                   help=f"RBF filename to load (default: {DEFAULT_RBF})")
    p.add_argument("--wait", type=float, default=12.0,
                   help="bench_run --wait per scene (default 12)")
    p.add_argument("--out-dir", default="tools/benchmark_results_full",
                   help="Output directory for per-condition JSONs")
    p.add_argument("--conditions", default=None,
                   help=f"Comma-separated labels to run (default: all "
                        f"{len(CONDITIONS)})")
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
    for label, keys in conditions:
        ok = run_condition(args.host, args.rbf, label, keys,
                           args.wait, out_dir)
        results[label] = "ok" if ok else "FAILED"

    print("\n\n========== SUMMARY ==========")
    for label, status in results.items():
        print(f"  {label:<14s} {status}")
    return 0 if all(s == "ok" for s in results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
