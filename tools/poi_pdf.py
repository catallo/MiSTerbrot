#!/usr/bin/env python3
"""Compose a PDF reference sheet of all POIs (one row per POI).

Reads tools/poi_master.json and screenshots/poi/idx_NNN_*.png and produces
a multi-page A4 PDF where each POI occupies a single horizontal row:
  [thumbnail] [#NN  NAME (category)] [coords cx/cy] [zoom + magnification] [note]

Outputs: tools/poi_catalog.pdf
"""

import json
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
THUMB_DIR = ROOT / "screenshots" / "poi"
OUT_PDF = ROOT / "tools" / "poi_catalog.pdf"

# A4 at 150 DPI
PAGE_W, PAGE_H = 1240, 1754
MARGIN_X = 50
MARGIN_TOP = 80
MARGIN_BOT = 60

ROW_H = 110  # one POI per row
THUMB_W, THUMB_H = 130, 98  # 4:3, leaves headroom in row

# Column x-positions inside a row (relative to row start)
COL_THUMB = 0
COL_NAME  = THUMB_W + 20      # 150
COL_COORD = 540               # cx / cy column
COL_ZOOM  = 830               # zoom + magnification
COL_NOTE  = 1030              # note (rest of row)
ROW_TEXT_W = PAGE_W - 2 * MARGIN_X


def safe_filename(name):
    s = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower()
    return s or "unnamed"


def load_font(size, bold=False):
    for path in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold
                 else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                 "/usr/share/fonts/TTF/DejaVuSans.ttf",
                 "/usr/share/fonts/dejavu/DejaVuSans.ttf"]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


F_TITLE = load_font(20, bold=True)
F_NAME  = load_font(18, bold=True)
F_CAT   = load_font(13)
F_MONO  = load_font(13)
F_NOTE  = load_font(13)
F_PAGE  = load_font(20, bold=True)
F_HEAD  = load_font(13, bold=True)


def wrap_lines(d, text, font, max_w, max_lines=3):
    words = text.split()
    lines = []
    cur = ""
    for w in words:
        tentative = (cur + " " + w).strip()
        bbox = d.textbbox((0, 0), tentative, font=font)
        if bbox[2] - bbox[0] > max_w and cur:
            lines.append(cur)
            cur = w
        else:
            cur = tentative
        if len(lines) >= max_lines:
            break
    if cur and len(lines) < max_lines:
        lines.append(cur)
    return lines


def draw_row(page, x, y, idx, poi):
    d = ImageDraw.Draw(page)
    name = poi["name"]
    cx, cy = float(poi["cx"]), float(poi["cy"])
    zoom = float(poi["zoom_level"])
    cat = poi.get("category", "")
    note = poi.get("note", "")

    # thumbnail
    thumb_path = THUMB_DIR / f"idx_{idx:03d}_{safe_filename(name)}.png"
    if thumb_path.exists():
        thumb = Image.open(thumb_path).convert("RGB")
        thumb = thumb.resize((THUMB_W, THUMB_H), Image.LANCZOS)
        page.paste(thumb, (x + COL_THUMB, y))
    else:
        d.rectangle([x + COL_THUMB, y, x + COL_THUMB + THUMB_W, y + THUMB_H],
                    outline=(0, 0, 0), fill=(240, 240, 240))

    # name + category
    d.text((x + COL_NAME, y),       f"#{idx:02d}  {name}", fill=(0, 0, 0), font=F_NAME)
    d.text((x + COL_NAME, y + 26),  f"({cat})",            fill=(100, 100, 100), font=F_CAT)

    # coords (mono)
    d.text((x + COL_COORD, y),      f"cx = {cx:+.10f}", fill=(0, 0, 0), font=F_MONO)
    d.text((x + COL_COORD, y + 20), f"cy = {cy:+.10f}", fill=(0, 0, 0), font=F_MONO)

    # zoom + magnification
    d.text((x + COL_ZOOM, y),      f"zoom: X2^{zoom:.2f}",   fill=(0, 0, 0), font=F_MONO)
    d.text((x + COL_ZOOM, y + 20), f"mag ≈ {2**zoom:.2g}×",  fill=(0, 0, 0), font=F_MONO)

    # note (wrapped, max 4 lines)
    if note:
        note_lines = wrap_lines(d, note, F_NOTE, ROW_TEXT_W - COL_NOTE, max_lines=4)
        for i, ln in enumerate(note_lines):
            d.text((x + COL_NOTE, y + i * 18), ln, fill=(60, 60, 60), font=F_NOTE)

    # separator line below row
    d.line([(x, y + ROW_H - 6), (x + ROW_TEXT_W, y + ROW_H - 6)],
           fill=(200, 200, 200), width=1)


def draw_header(page, page_num, total_pages, page_first_idx, page_last_idx):
    d = ImageDraw.Draw(page)
    d.text((MARGIN_X, 22),
           f"MiSTerbrot POI Catalog — page {page_num}/{total_pages}  (#{page_first_idx:02d}–#{page_last_idx:02d})",
           fill=(0, 0, 0), font=F_PAGE)
    d.line([(MARGIN_X, 60), (PAGE_W - MARGIN_X, 60)], fill=(0, 0, 0), width=2)
    # column headers
    d.text((MARGIN_X + COL_NAME,  64), "POI",    fill=(80, 80, 80), font=F_HEAD)
    d.text((MARGIN_X + COL_COORD, 64), "COORDS", fill=(80, 80, 80), font=F_HEAD)
    d.text((MARGIN_X + COL_ZOOM,  64), "ZOOM",   fill=(80, 80, 80), font=F_HEAD)
    d.text((MARGIN_X + COL_NOTE,  64), "NOTE",   fill=(80, 80, 80), font=F_HEAD)


def main():
    with open(MASTER_JSON) as f:
        pois = json.load(f)

    rows_per_page = (PAGE_H - MARGIN_TOP - MARGIN_BOT) // ROW_H
    total_pages = (len(pois) + rows_per_page - 1) // rows_per_page

    pages = []
    for page_idx in range(total_pages):
        page = Image.new("RGB", (PAGE_W, PAGE_H), (255, 255, 255))
        first = page_idx * rows_per_page
        last = min(first + rows_per_page, len(pois)) - 1
        draw_header(page, page_idx + 1, total_pages, first, last)
        for row_i in range(rows_per_page):
            gi = first + row_i
            if gi >= len(pois):
                break
            y = MARGIN_TOP + row_i * ROW_H
            draw_row(page, MARGIN_X, y, gi, pois[gi])
        pages.append(page)

    pages[0].save(OUT_PDF, save_all=True, append_images=pages[1:], resolution=150.0)
    print(f"Wrote {OUT_PDF}: {len(pages)} pages, {len(pois)} POIs, {rows_per_page} rows/page")


if __name__ == "__main__":
    main()
