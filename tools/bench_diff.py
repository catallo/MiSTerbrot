#!/usr/bin/env python3
"""Diff two benchmark result JSON files produced by `tools/bench_run.py`.

Prints a per-scene side-by-side table with ratio and percentage delta, plus
a geometric-mean speedup summary. Useful for quantifying Track A wins.

Usage:
    python3 tools/bench_diff.py baseline.json after-a1.json
    python3 tools/bench_diff.py before.json  after.json  --threshold 0.1
"""

import argparse
import json
import math
import sys
from pathlib import Path


def load(path):
    return json.loads(Path(path).read_text())


def fmt_pct(ratio):
    pct = (ratio - 1.0) * 100.0
    sign = "+" if pct >= 0 else ""
    return f"{sign}{pct:.1f}%"


def main():
    p = argparse.ArgumentParser(description="Diff two bench_run.py result JSONs")
    p.add_argument("before", help="baseline JSON path")
    p.add_argument("after", help="post-optimisation JSON path")
    p.add_argument("--threshold", type=float, default=0.10,
                   help="Highlight rows with |ratio-1| >= this (default 0.10 = 10%)")
    args = p.parse_args()

    a = load(args.before)
    b = load(args.after)

    by_name_a = {r["name"]: r for r in a["results"] if "fps" in r}
    by_name_b = {r["name"]: r for r in b["results"] if "fps" in r}

    only_a = sorted(set(by_name_a) - set(by_name_b))
    only_b = sorted(set(by_name_b) - set(by_name_a))
    both   = sorted(set(by_name_a) & set(by_name_b))

    if only_a:
        print(f"# WARNING: scenes only in BEFORE: {only_a}", file=sys.stderr)
    if only_b:
        print(f"# WARNING: scenes only in AFTER:  {only_b}", file=sys.stderr)

    label_a = a.get("label") or Path(args.before).stem
    label_b = b.get("label") or Path(args.after).stem
    ts_a = a.get("timestamp", "?")
    ts_b = b.get("timestamp", "?")

    print(f"# diff  {label_a} ({ts_a})  →  {label_b} ({ts_b})")
    print()
    print(f"      {'scene':<24}  {'before':>10}  {'after':>10}  {'ratio':>8}  {'delta':>9}")
    print(f"      {'-'*24}  {'-'*10}  {'-'*10}  {'-'*8}  {'-'*9}")

    geom_log = 0.0
    n = 0
    for name in both:
        f_a = by_name_a[name]["fps"]
        f_b = by_name_b[name]["fps"]
        if f_a > 0:
            ratio = f_b / f_a
        else:
            ratio = float("inf") if f_b > 0 else 1.0
        mark = "  *  " if abs(ratio - 1.0) >= args.threshold else "     "
        print(f"{mark} {name:<24}  {f_a:>10.2f}  {f_b:>10.2f}  "
              f"{ratio:>7.2f}x  {fmt_pct(ratio):>9}")
        if f_a > 0 and ratio > 0 and math.isfinite(ratio):
            geom_log += math.log(ratio)
            n += 1
    if n:
        gmean = math.exp(geom_log / n)
        print()
        print(f"      Geometric mean speedup: {gmean:.2f}x ({fmt_pct(gmean)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
