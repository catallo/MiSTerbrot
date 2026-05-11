#!/usr/bin/env python3
"""Template-match OCR for the MiSTerbrot overlay font.

The overlay uses a fixed 5×5 binary pixel font defined inline in
rtl/text_overlay.v (the `glyph_bits` case statement). This module:

1. Parses the Verilog glyph table at import time → in-memory dict
   {ascii_code: 5×5 numpy array of 0/1}.
2. Locates the bottom-left "target" overlay region in a misterclaw
   screenshot (FPGA in 640 mode → 640×480 output via 2× vertical scaler).
3. Slices the POI-name line into 48 character cells, thresholds each
   to a 5×5 binary glyph, and matches each cell against every template
   via Hamming distance.
4. Concatenates the best-match chars into the recognised string.

For the FPGA's fixed bitmap font this is effectively 100% accurate —
no anti-aliasing, no kerning, no font variants.

Usage:
    from poi_ocr import read_target_line
    text = read_target_line("screenshot.png")  # e.g. "P6 SUB BULB | NEON"
"""

import re
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
TEXT_OVERLAY_V = ROOT / "rtl" / "text_overlay.v"

# Overlay region constants (native 320/640-mode pixel coords from text_overlay.v).
# TARGET_X/Y are the region origin, then text starts +2 pixels in.
TARGET_X_NATIVE = 5 + 2          # = 7
TARGET_Y_NATIVE = 216 + 2        # = 218 (first overlay line)
TARGET_LINE_LEN = 48             # chars per line
GLYPH_W = 5
GLYPH_H = 5
LINE_PITCH = 10                  # native pixels between line starts


def _parse_font():
    """Extract the `glyph_bits` case-statement → {ascii: 5×5 ndarray}."""
    text = TEXT_OVERLAY_V.read_text()
    # Find the function body
    m = re.search(r"function\s*\[24:0\]\s*glyph_bits\s*;(.*?)endfunction",
                  text, re.DOTALL)
    if not m:
        raise RuntimeError("glyph_bits function not found in text_overlay.v")
    body = m.group(1)
    # Each glyph entry: `7'd<ASCII>:  glyph_bits = 25'b<bits>;`
    glyphs = {}
    for line_m in re.finditer(
        r"7'd(\d+)\s*:\s*glyph_bits\s*=\s*25'b([01_]+)\s*;",
        body,
    ):
        code = int(line_m.group(1))
        bits = line_m.group(2).replace("_", "")
        if len(bits) != 25:
            continue
        arr = np.array([int(b) for b in bits], dtype=np.uint8).reshape(5, 5)
        glyphs[code] = arr
    return glyphs


_GLYPHS = _parse_font()
_CODES = sorted(_GLYPHS.keys())


def _to_char(code):
    return chr(code) if 32 <= code < 127 else "?"


def _binarise_text(arr_rgb, white_min=230, chroma_spread_max=15):
    """Per-pixel 'is near-white' classifier — overlay text is RGB ~(255,255,255).

    Tolerates the slightly off-white pixels at glyph stroke edges (from PNG
    re-encoding) but rejects bright fractal palette colours (yellow has B≈0
    → fails min_ch test; cyan has R≪G,B → fails chroma_spread).
    """
    r, g, b = arr_rgb[..., 0].astype(np.int16), arr_rgb[..., 1].astype(np.int16), arr_rgb[..., 2].astype(np.int16)
    min_ch = np.minimum(np.minimum(r, g), b)
    max_ch = np.maximum(np.maximum(r, g), b)
    return ((min_ch >= white_min) & ((max_ch - min_ch) <= chroma_spread_max)).astype(np.uint8)


def _cell_to_glyph(cell_bin):
    """Reduce a 5×N (typically 5×10 for the FPGA's 2× vertical scaler) binary
    cell to a 5×5 template by taking every other row. Falls back to any-row-set
    if the cell is taller than expected."""
    h = cell_bin.shape[0]
    if h == 5:
        return cell_bin
    if h == 10:
        return cell_bin[::2]
    # Generic: downsample to 5 rows by max-pool
    rows_per = h // 5
    if rows_per < 1:
        return None
    out = np.zeros((5, 5), dtype=np.uint8)
    for i in range(5):
        chunk = cell_bin[i * rows_per:(i + 1) * rows_per]
        out[i] = chunk.max(axis=0)
    return out


def _best_match(cell_5x5):
    """Hamming-distance match against every template. Return (ascii_code, dist)."""
    best_code = 32  # default to space
    best_dist = 26  # > max possible (5*5+1)
    for code, tpl in _GLYPHS.items():
        d = int(np.sum(cell_5x5 != tpl))
        if d < best_dist:
            best_dist = d
            best_code = code
    return best_code, best_dist


def _find_text_origin(bin_img, y0, y1, expected_x_range=(0, 30)):
    """Find the first column with a near-white pixel in any row of [y0..y1].

    Auto-detects the actual text origin so we don't depend on pixel-perfect
    offsets from the FPGA's video timing.
    """
    band = bin_img[y0:y1]
    col_has_white = band.max(axis=0)
    for x in range(expected_x_range[0], expected_x_range[1]):
        if col_has_white[x]:
            return x
    return expected_x_range[0]


def read_target_line(image_path, mode_640=True, line_idx=0,
                    line_len=TARGET_LINE_LEN, verbose=False):
    """Read one line from the bottom-left overlay region.

    Args:
      image_path: path to misterclaw screenshot.
      mode_640: True if FPGA is in 640 mode (horizontal 1:1), False for 320
                mode (horizontal 2× scaler).
      line_idx: 0 = POI name | palette, 1 = X/Y/zoom coords.
      line_len: characters in the line (TARGET_LINE_LEN = 48).
    Returns:
      decoded string (whitespace-trimmed on the right).
    """
    img = np.asarray(Image.open(image_path).convert("RGB"))
    h_img, w_img = img.shape[:2]
    if h_img != 480 or w_img != 640:
        raise ValueError(f"expected 640×480 screenshot, got {w_img}×{h_img}")

    # Scaler: horizontal 2× if 320 mode, 1× if 640 mode. Vertical always 2×.
    h_scale = 1 if mode_640 else 2
    v_scale = 2
    glyph_w_screen = GLYPH_W * h_scale          # 5 or 10
    glyph_h_screen = GLYPH_H * v_scale          # 10
    y0 = (TARGET_Y_NATIVE + line_idx * LINE_PITCH) * v_scale  # 436 or 456

    bin_img = _binarise_text(img)
    # Auto-find horizontal origin: nominal is TARGET_X_NATIVE * h_scale, but the
    # FPGA's video pipeline can introduce a 1-pixel offset. Scan for the first
    # column containing white in this line's row band.
    nominal_x = TARGET_X_NATIVE * h_scale
    x0 = _find_text_origin(bin_img, y0, y0 + glyph_h_screen,
                            expected_x_range=(nominal_x - 2, nominal_x + 5))

    chars = []
    for c in range(line_len):
        cell_x0 = x0 + c * glyph_w_screen
        cell_y0 = y0
        cell = bin_img[cell_y0:cell_y0 + glyph_h_screen,
                       cell_x0:cell_x0 + glyph_w_screen]
        # Horizontal scale-down if 320 mode: each native pixel is 2 screen pixels wide.
        if h_scale == 2:
            cell = cell[:, ::2]
        glyph_5x5 = _cell_to_glyph(cell)
        if glyph_5x5 is None or glyph_5x5.shape != (5, 5):
            chars.append("?")
            continue
        code, dist = _best_match(glyph_5x5)
        if verbose:
            print(f"  col {c:2d} (x={cell_x0}): dist={dist:2d} → {_to_char(code)!r}")
        # If even the best match is implausibly far, emit space (likely no text here)
        chars.append(_to_char(code) if dist <= 8 else " ")
    return "".join(chars).rstrip()


def read_poi_name(image_path, mode_640=True):
    """Convenience: read POI-name line, strip off the ' | <palette>' suffix."""
    line = read_target_line(image_path, mode_640=mode_640, line_idx=0)
    if "|" in line:
        line = line.split("|", 1)[0]
    return line.strip()


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <screenshot.png>", file=sys.stderr)
        sys.exit(1)
    print(read_target_line(sys.argv[1], verbose=True))
    print("POI name:", repr(read_poi_name(sys.argv[1])))
