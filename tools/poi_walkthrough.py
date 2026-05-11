#!/usr/bin/env python3
"""POI walkthrough: snap every POI on the running MiSTerbrot core via M-key,
screenshot, and pair each FPGA capture with its Python-rendered thumbnail.

For each POI in the auto-zoom playlist:
  1. Press M (snap_next) via misterclaw-send → core jumps to the POI's
     canonical center+zoom and freezes in S_HOLD.
  2. Sleep PAUSE_SEC to let the view settle.
  3. Screenshot the FPGA output.
  4. Match the screenshot to a Python thumbnail by greyscale-correlation
     of the central fractal area (overlay text strips ignored).
  5. Drop both into a per-POI folder with a side-by-side comparison.

Output layout:
  screenshots/poi_compare/
    idx_000_p6_sub_bulb/
      fpga.png       — what the FPGA is rendering
      python.png     — what the Python renderer produced for the same POI
      compare.png    — side-by-side (FPGA | Python)
    idx_001_p3_island/
      ...
    _summary.txt     — per-POI match score + warnings

Usage:
  python3 tools/poi_walkthrough.py

Env vars (all optional):
  MISTER_HOST=10.0.0.8        MiSTer IP (default 10.0.0.8)
  PAUSE_SEC=3                 seconds between M-press and screenshot (default 3)
  MAX_PRESSES=200             safety cap on M-presses (default 2*N_POIs)
  WARMUP_PRESSES=0            extra M-presses before starting capture (default 0)

Requires: numpy, Pillow. Both already installed (poi_render.py uses them).

The FPGA's playlist is shuffled per boot — we don't know the order in advance,
so the script uses image similarity to identify each capture. It keeps pressing
M until every POI has been seen (or MAX_PRESSES is hit). Total time for 67 POIs
at PAUSE_SEC=3: roughly 5 minutes.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
THUMB_DIR = ROOT / "screenshots" / "poi"
OUT_DIR = ROOT / "screenshots" / "poi_compare"
MISTERCLAW = str(ROOT / "tools" / "misterclaw-send")

HOST = os.environ.get("MISTER_HOST", "10.0.0.8")
PAUSE_SEC = float(os.environ.get("PAUSE_SEC", "3"))
WARMUP_PRESSES = int(os.environ.get("WARMUP_PRESSES", "0"))


def safe_filename(name):
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower() or "unnamed"


def press_m():
    subprocess.run(
        [MISTERCLAW, "--host", HOST, "input", "type", "M"],
        check=True, capture_output=True, timeout=10,
    )


def screenshot_to(path):
    subprocess.run(
        [MISTERCLAW, "--host", HOST, "screenshot", "--output", str(path)],
        check=True, capture_output=True, timeout=15,
    )


def image_signature(path, size=(48, 36)):
    """Greyscale, crop out overlay text bands, downsample, mean-normalise.

    The FPGA overlay sits in the top ~8% and bottom ~12% of the frame; cropping
    them off makes matching robust to palette differences and overlay text. The
    Python thumbnails have no overlay but the same crop is applied so both sides
    have matching content.
    """
    img = Image.open(path).convert("L")
    w, h = img.size
    img = img.crop((0, int(h * 0.08), w, int(h * 0.88)))
    img = img.resize(size, Image.LANCZOS)
    arr = np.asarray(img, dtype=np.float32)
    arr -= arr.mean()
    n = np.linalg.norm(arr)
    if n > 0:
        arr /= n
    return arr.flatten()


def best_match(fpga_sig, py_sigs):
    """Return (idx, score) of best Python thumbnail (cosine similarity)."""
    scores = np.array([float(np.dot(fpga_sig, s)) for _, s in py_sigs])
    best = int(np.argmax(scores))
    return py_sigs[best][0], float(scores[best])


def make_side_by_side(fpga_path, python_path, out_path):
    fpga = Image.open(fpga_path).convert("RGB")
    py = Image.open(python_path).convert("RGB")
    h = 320  # display height — both images scaled to this
    fpga = fpga.resize((int(fpga.width * h / fpga.height), h), Image.LANCZOS)
    py = py.resize((int(py.width * h / py.height), h), Image.LANCZOS)
    gap = 6
    composite = Image.new("RGB", (fpga.width + py.width + gap, h), (32, 32, 32))
    composite.paste(fpga, (0, 0))
    composite.paste(py, (fpga.width + gap, 0))
    composite.save(out_path)


def main():
    if not Path(MISTERCLAW).exists():
        print(f"ERROR: misterclaw-send not at {MISTERCLAW}", file=sys.stderr)
        sys.exit(1)

    with open(MASTER_JSON) as f:
        pois = json.load(f)
    n = len(pois)
    max_presses = int(os.environ.get("MAX_PRESSES", str(2 * n)))

    # Pre-compute signatures for every Python thumbnail.
    py_sigs = []
    for i, p in enumerate(pois):
        thumb = THUMB_DIR / f"idx_{i:03d}_{safe_filename(p['name'])}.png"
        if not thumb.exists():
            print(f"  WARN: missing thumb for idx {i:03d} {p['name']}", file=sys.stderr)
            continue
        py_sigs.append((i, image_signature(thumb)))

    shutil.rmtree(OUT_DIR, ignore_errors=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"MiSTer host    : {HOST}")
    print(f"POIs to capture: {n}")
    print(f"Pause per snap : {PAUSE_SEC}s")
    print(f"Output         : {OUT_DIR}/")
    print()

    # Optional warm-up: drain a few presses if the user wants to skip past the
    # currently-displayed POI (useful when the core was already running).
    for _ in range(WARMUP_PRESSES):
        press_m()
        time.sleep(PAUSE_SEC)

    seen = set()
    summary_lines = ["# POI walkthrough summary", "# press  idx  name                  score"]

    for press in range(1, max_presses + 1):
        if len(seen) >= n:
            break

        try:
            press_m()
        except Exception as e:
            print(f"  [press {press}] M failed: {e}", file=sys.stderr)
            continue
        time.sleep(PAUSE_SEC)

        tmp = f"/tmp/poi_walk_{press:03d}.png"
        try:
            screenshot_to(tmp)
        except Exception as e:
            print(f"  [press {press}] screenshot failed: {e}", file=sys.stderr)
            continue

        sig = image_signature(tmp)
        idx, score = best_match(sig, py_sigs)

        if idx in seen:
            print(f"  [press {press:3d}/{max_presses}] dup → idx {idx:3d} {pois[idx]['name']:<20} score={score:+.3f}  (skipped)")
            os.remove(tmp)
            continue

        seen.add(idx)
        poi = pois[idx]
        folder = OUT_DIR / f"idx_{idx:03d}_{safe_filename(poi['name'])}"
        folder.mkdir(parents=True, exist_ok=True)
        shutil.move(tmp, folder / "fpga.png")
        py_thumb = THUMB_DIR / f"idx_{idx:03d}_{safe_filename(poi['name'])}.png"
        if py_thumb.exists():
            shutil.copy(py_thumb, folder / "python.png")
            try:
                make_side_by_side(folder / "fpga.png", folder / "python.png", folder / "compare.png")
            except Exception as e:
                print(f"  WARN: compose failed for {folder.name}: {e}", file=sys.stderr)

        line = f"{press:3d}    {idx:3d}  {poi['name']:<20} {score:+.3f}"
        summary_lines.append(line)
        print(f"  [press {press:3d}/{max_presses}]      → idx {idx:3d} {poi['name']:<20} score={score:+.3f}  → {folder.name}/")

    missed = sorted(set(range(n)) - seen)
    if missed:
        summary_lines.append("")
        summary_lines.append(f"# MISSED {len(missed)} POIs: {missed}")
    summary_lines.append("")
    summary_lines.append(f"# Captured {len(seen)}/{n} POIs in {press} presses")

    (OUT_DIR / "_summary.txt").write_text("\n".join(summary_lines) + "\n")

    print()
    print(f"Captured {len(seen)}/{n} POIs. Summary: {OUT_DIR}/_summary.txt")
    if missed:
        print(f"Missed (low match scores or never visited): {missed[:10]}{'...' if len(missed) > 10 else ''}")
        print(f"  Re-run with WARMUP_PRESSES set, or increase MAX_PRESSES.")
    print()
    print(f"Browse {OUT_DIR}/<idx>_<name>/compare.png for per-POI side-by-side.")


if __name__ == "__main__":
    main()
