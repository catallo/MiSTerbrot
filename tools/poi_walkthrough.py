#!/usr/bin/env python3
"""POI walkthrough: snap every POI on the running MiSTerbrot core via M-key,
screenshot, and pair each FPGA capture with its Python-rendered thumbnail.

For each POI in the auto-zoom playlist:
  1. Press M (snap_next) via misterclaw-send → core jumps to the POI's
     canonical center+zoom and freezes in S_HOLD.
  2. Sleep PAUSE_SEC to let the view settle.
  3. Screenshot the FPGA output.
  4. OCR the overlay's bottom-left corner (POI name | palette name) using
     tesseract, then fuzzy-match the parsed name against tools/poi_master.json.
  5. Drop both into a per-POI folder with a side-by-side comparison.

Output layout:
  screenshots/poi_compare/
    idx_000_p6_sub_bulb/
      fpga.png       — what the FPGA is rendering
      python.png     — what the Python renderer produced for the same POI
      compare.png    — side-by-side (FPGA | Python)
    idx_001_p3_island/
      ...
    _unmatched/                 — OCR results that didn't fuzzy-match any POI
      press_NNN_fpga.png        — raw capture
      press_NNN_ocr.txt         — what tesseract read
    _summary.txt                — per-POI match log + OCR text

Usage:
  python3 tools/poi_walkthrough.py

Env vars (all optional):
  MISTER_HOST=10.0.0.8        MiSTer IP (default 10.0.0.8)
  PAUSE_SEC=3                 seconds between M-press and screenshot (default 3)
  MAX_PRESSES=200             safety cap on M-presses (default 2*N_POIs)

Requires: tesseract (system binary; tested with 5.5.0), numpy, Pillow.
"""

import difflib
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

# Template-match OCR for the FPGA's fixed 5×5 bitmap font (parses
# rtl/text_overlay.v at import). Near-100% accurate vs the prior tesseract +
# fuzzy-match path which struggled with the bitmap font.
sys_path_inserted = False
try:
    from poi_ocr import read_poi_name as _ocr_poi_name
except ImportError:
    import sys as _sys
    _sys.path.insert(0, str(Path(__file__).resolve().parent))
    from poi_ocr import read_poi_name as _ocr_poi_name

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
THUMB_DIR = ROOT / "screenshots" / "poi"
OUT_DIR = ROOT / "screenshots" / "poi_compare"
UNMATCHED_DIR = OUT_DIR / "_unmatched"
MISTERCLAW = str(ROOT / "tools" / "misterclaw-send")

HOST = os.environ.get("MISTER_HOST", "10.0.0.8")
PAUSE_SEC = float(os.environ.get("PAUSE_SEC", "3"))

# Fuzzy-match threshold (0..1). Below this, treat as unmatched.
NAME_MATCH_THRESHOLD = 0.45


def safe_filename(name):
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower() or "unnamed"


def press_m():
    subprocess.run(
        [MISTERCLAW, "--host", HOST, "input", "type", "M"],
        check=True, capture_output=True, timeout=10,
    )


def prepare_overlay():
    """Press G + L so the overlay is dim-backed (readable on any palette)
    and stays visible (auto-hide disabled). Both are sticky keyboard
    overrides until core reset. Must run before any screenshot loop."""
    for key in ("G", "L"):
        subprocess.run(
            [MISTERCLAW, "--host", HOST, "input", "type", key],
            check=True, capture_output=True, timeout=10,
        )


def screenshot_to(path):
    subprocess.run(
        [MISTERCLAW, "--host", HOST, "screenshot", "--output", str(path)],
        check=True, capture_output=True, timeout=15,
    )


def ocr_overlay(image_path):
    """Read POI name from the overlay via template-matching against the FPGA's
    fixed 5×5 pixel font (parsed from rtl/text_overlay.v at import time)."""
    try:
        return _ocr_poi_name(image_path, mode_640=True)
    except Exception:
        return ""


def _ocr_overlay_old(image_path):
    """Legacy tesseract path — kept for reference."""
    img = Image.open(image_path).convert("RGB")
    w, h = img.size
    crop = img.crop((0, int(h * 0.85), int(w * 0.50), int(h * 0.99)))
    arr = np.asarray(crop, dtype=np.int16)
    r_ch, g_ch, b_ch = arr[..., 0], arr[..., 1], arr[..., 2]
    min_ch = np.minimum(np.minimum(r_ch, g_ch), b_ch)
    max_ch = np.maximum(np.maximum(r_ch, g_ch), b_ch)
    near_white = (min_ch > 230) & ((max_ch - min_ch) < 15)
    mask = (~near_white).astype(np.uint8) * 255
    mask_img = Image.fromarray(mask, mode="L")
    mask_img = mask_img.resize((mask_img.width * 4, mask_img.height * 4), Image.NEAREST)
    mask_img.save("/tmp/poi_walk_ocr.png")
    proc = subprocess.run(
        ["tesseract", "/tmp/poi_walk_ocr.png", "-",
         "--psm", "6",
         "-c", "tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -,/"],
        capture_output=True, text=True, timeout=10,
    )
    # Return the first non-empty line (the POI name line); palette name is after "|"
    for line in proc.stdout.upper().splitlines():
        line = line.strip()
        if line and any(c.isalpha() for c in line):
            return line
    return ""


def parse_poi_name(ocr_text):
    """Strip the palette name (everything after ' | ') and trim."""
    if "|" in ocr_text:
        ocr_text = ocr_text.split("|", 1)[0]
    return ocr_text.strip()


def fuzzy_match(name, valid_names):
    """Best fuzzy match against canonical POI names. Returns (name, score) or (None, 0)."""
    if not name:
        return None, 0.0
    candidates = list(valid_names)
    matches = difflib.get_close_matches(name, candidates, n=1, cutoff=NAME_MATCH_THRESHOLD)
    if matches:
        score = difflib.SequenceMatcher(None, name, matches[0]).ratio()
        return matches[0], score
    # Try removing spaces / punctuation and matching against squashed names
    sq = re.sub(r"[^A-Z0-9]", "", name)
    squashed = {re.sub(r"[^A-Z0-9]", "", v.upper()): v for v in candidates}
    matches = difflib.get_close_matches(sq, list(squashed.keys()), n=1, cutoff=NAME_MATCH_THRESHOLD)
    if matches:
        score = difflib.SequenceMatcher(None, sq, matches[0]).ratio()
        return squashed[matches[0]], score
    return None, 0.0


def make_side_by_side(fpga_path, python_path, out_path):
    """Side-by-side at the FPGA's native 640×240 framebuffer resolution.

    misterclaw captures 640×480 (the MiSTer scaler doubles vertically for HDMI),
    so we shrink height by half to recover the 1:1 framebuffer aspect. Python
    thumb is already 640×240. Both sides end up rendering identical complex-
    plane extents at matching pixel pitch — direct visual comparison.
    """
    fpga = Image.open(fpga_path).convert("RGB")
    py = Image.open(python_path).convert("RGB")
    target_w, target_h = 640, 240
    fpga = fpga.resize((target_w, target_h), Image.LANCZOS)
    py = py.resize((target_w, target_h), Image.LANCZOS)
    gap = 6
    composite = Image.new("RGB", (target_w * 2 + gap, target_h), (32, 32, 32))
    composite.paste(fpga, (0, 0))
    composite.paste(py, (target_w + gap, 0))
    composite.save(out_path)


def main():
    if not Path(MISTERCLAW).exists():
        print(f"ERROR: misterclaw-send not at {MISTERCLAW}", file=sys.stderr)
        sys.exit(1)
    if subprocess.run(["which", "tesseract"], capture_output=True).returncode != 0:
        print("ERROR: tesseract not in PATH (apt install tesseract-ocr)", file=sys.stderr)
        sys.exit(1)

    with open(MASTER_JSON) as f:
        pois = json.load(f)
    n = len(pois)
    max_presses = int(os.environ.get("MAX_PRESSES", str(2 * n)))

    # Map upper-case POI name → index in JSON
    name_to_idx = {p["name"].upper(): i for i, p in enumerate(pois)}
    valid_names = list(name_to_idx.keys())

    shutil.rmtree(OUT_DIR, ignore_errors=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    UNMATCHED_DIR.mkdir(parents=True, exist_ok=True)

    print(f"MiSTer host    : {HOST}")
    print(f"POIs to capture: {n}")
    print(f"Pause per snap : {PAUSE_SEC}s")
    print(f"Output         : {OUT_DIR}/")
    print()

    # Force overlay to dim BG + always-visible. Without this, captures on
    # bright palettes are unreadable and the auto-hide timer kills the overlay
    # between snaps.
    try:
        prepare_overlay()
        print("Pressed G (dim BG) + L (disable auto-hide).")
    except Exception as e:
        print(f"WARN: prepare_overlay failed ({e}); captures may be unreadable.",
              file=sys.stderr)
    print()

    seen = set()
    summary_lines = ["# POI walkthrough summary",
                     "# press  idx  poi_name             ocr_text                 score"]

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

        try:
            ocr_raw = ocr_overlay(tmp)
        except Exception as e:
            print(f"  [press {press}] OCR failed: {e}", file=sys.stderr)
            ocr_raw = ""
        ocr_name = parse_poi_name(ocr_raw)
        match_name, score = fuzzy_match(ocr_name, valid_names)

        if match_name is None:
            # Park the unmatched capture for manual inspection
            shutil.move(tmp, UNMATCHED_DIR / f"press_{press:03d}_fpga.png")
            (UNMATCHED_DIR / f"press_{press:03d}_ocr.txt").write_text(ocr_raw + "\n")
            print(f"  [press {press:3d}/{max_presses}] OCR: {ocr_raw!r:<35} → UNMATCHED")
            summary_lines.append(f"{press:3d}    ---  ---                 {ocr_name:<24} {score:.2f}")
            continue

        idx = name_to_idx[match_name]
        if idx in seen:
            print(f"  [press {press:3d}/{max_presses}] dup → idx {idx:3d} {match_name:<20} (ocr={ocr_name!r})")
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

        summary_lines.append(f"{press:3d}    {idx:3d}  {match_name:<20} {ocr_name:<24} {score:.2f}")
        print(f"  [press {press:3d}/{max_presses}]      → idx {idx:3d} {match_name:<20} (ocr={ocr_name!r}, score={score:.2f})")

    missed = sorted(set(range(n)) - seen)
    summary_lines.append("")
    if missed:
        summary_lines.append(f"# MISSED {len(missed)} POIs: {missed}")
    summary_lines.append(f"# Captured {len(seen)}/{n} POIs in {press} presses")
    (OUT_DIR / "_summary.txt").write_text("\n".join(summary_lines) + "\n")

    print()
    print(f"Captured {len(seen)}/{n} POIs. Summary: {OUT_DIR}/_summary.txt")
    if missed:
        print(f"Missed: {[pois[i]['name'] for i in missed[:10]]}{'...' if len(missed) > 10 else ''}")
        print(f"Unmatched OCR captures (if any) are in {UNMATCHED_DIR}/")
    print(f"Browse {OUT_DIR}/<idx>_<name>/compare.png for per-POI side-by-side.")


if __name__ == "__main__":
    main()
