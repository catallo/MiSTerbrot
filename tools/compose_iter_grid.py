#!/usr/bin/env python3
"""Compose per-POI iter-comparison grids for visual review.

For each POI in the latest bench_iter_profile sweep, build a single PNG
containing the 6 screenshots (Auto, 128, 256, 512, 1024, 2048) laid out
in a 2×3 grid with labels showing iter setting, F10/fps, structural
diff vs reference, and the recommended verdict.

Reads:
  - screenshots/bench_iter_profile_<latest>/iter_<label>/bench_NN.png
  - tools/profile_iter_report.json (for rec / diff / fps per POI)

Writes:
  - screenshots/bench_iter_profile_<latest>/per_poi/<idx>_<safe_name>.png
"""

import json
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SHOTS_ROOT = ROOT / "screenshots"
REPORT_JSON = ROOT / "tools" / "profile_iter_report.json"

SETTING_ORDER = ["Auto", "128", "256", "512", "1024", "2048"]
PANEL_W, PANEL_H = 640, 480
LABEL_H = 60
COLS, ROWS = 3, 2  # 3 wide × 2 tall


def safe_name(s: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]", "_", s).strip("_")


def latest_profile_dir() -> Path:
    dirs = sorted(SHOTS_ROOT.glob("bench_iter_profile_*"))
    if not dirs:
        raise SystemExit("ERROR: no bench_iter_profile_* directories found")
    return dirs[-1]


def load_font(size: int = 18) -> ImageFont.FreeTypeFont:
    # Try a few common monospace fonts; fall back to default
    for cand in [
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/System/Library/Fonts/Menlo.ttc",
    ]:
        if Path(cand).exists():
            return ImageFont.truetype(cand, size=size)
    return ImageFont.load_default()


def main() -> int:
    profile_dir = latest_profile_dir()
    print(f"Profile dir: {profile_dir}")

    if not REPORT_JSON.exists():
        print(f"ERROR: {REPORT_JSON} not found — run tools/analyze_max_iter.py first")
        return 1
    report = {r["idx"]: r for r in json.loads(REPORT_JSON.read_text())}

    out_dir = profile_dir / "per_poi"
    out_dir.mkdir(parents=True, exist_ok=True)

    font_title = load_font(24)
    font_label = load_font(16)

    # Each iter_<label> dir holds bench_NN.png files.  Build a map:
    # idx -> {setting -> screenshot path}.
    shots = {}
    for setting in SETTING_ORDER:
        d = profile_dir / f"iter_{setting}"
        if not d.exists():
            continue
        for png in sorted(d.glob("bench_*.png")):
            idx = int(png.stem.split("_")[1])
            shots.setdefault(idx, {})[setting] = png

    composed = 0
    for idx in sorted(shots):
        per_setting = shots[idx]
        if len(per_setting) < 6:
            print(f"  [{idx:3d}] SKIP — only {len(per_setting)} of 6 settings present")
            continue
        rep = report.get(idx, {})
        name = rep.get("name", f"poi_{idx}")
        verdict = rep.get("verdict", "?")
        cur = rep.get("current_auto_max_iter", "?")
        rec = rep.get("recommended_max_iter", "?")

        # Composite canvas
        title_h = 40
        cell_h = PANEL_H + LABEL_H
        canvas_w = COLS * PANEL_W
        canvas_h = title_h + ROWS * cell_h
        canvas = Image.new("RGB", (canvas_w, canvas_h), color=(20, 20, 20))
        draw = ImageDraw.Draw(canvas)

        title = (f"#{idx:02d}  {name}    "
                 f"verdict={verdict}    current={cur}    recommended={rec}")
        draw.text((10, 8), title, fill=(220, 220, 220), font=font_title)

        # Lay out 2×3 — row 0: Auto/128/256, row 1: 512/1024/2048
        for i, setting in enumerate(SETTING_ORDER):
            r, c = divmod(i, COLS)
            x = c * PANEL_W
            y = title_h + r * cell_h
            png = per_setting.get(setting)
            if png and png.exists():
                im = Image.open(png).convert("RGB")
                if im.size != (PANEL_W, PANEL_H):
                    im = im.resize((PANEL_W, PANEL_H))
                canvas.paste(im, (x, y))
            else:
                draw.rectangle([x, y, x + PANEL_W, y + PANEL_H],
                               fill=(40, 40, 40))

            # Label below this panel
            ps = rep.get("per_setting", {}).get(setting, {})
            diff = ps.get("diff", 0) * 100
            fps = ps.get("fps", 0)
            is_rec = (
                (verdict == "PERF_WIN"   and str(rec) == setting) or
                (verdict == "NO_CHANGE"  and str(rec) == setting) or
                (verdict == "QUALITY_FIX" and str(rec) == setting) or
                (setting == "Auto" and rec == cur)
            )
            tag = " ← REC" if is_rec else ""
            label = f"iter={setting:<5}  diff={diff:5.2f}%  fps={fps:5.1f}{tag}"
            label_y = y + PANEL_H + 8
            colour = (0, 255, 0) if is_rec else (200, 200, 200)
            draw.text((x + 10, label_y), label, fill=colour, font=font_label)

        out_path = out_dir / f"{idx:03d}_{safe_name(name)}.png"
        canvas.save(out_path)
        composed += 1
        if composed % 10 == 0:
            print(f"  {composed} composed...")

    print(f"\nComposed {composed} per-POI grids to {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
