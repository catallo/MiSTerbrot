#!/usr/bin/env python3
"""Encode POI master list into 8.56 fixed-point block-RAM init tables.

Reads tools/poi_master.json. Produces:
  - rtl/poi_generated.vh : `POI_TABLE_INIT (auto_zoom.v poi_rom) and
                           `POI_NAME_INIT (text_overlay.v name_rom) plus the
                           `POI_*_LSB / width defines the RTL slices with
  - prints a roundtrip-verified summary table

8.56 format: 64-bit signed, 56 fractional bits. value = signed_int / 2**56.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASTER_JSON = ROOT / "tools" / "poi_master.json"
OUT_VH = ROOT / "rtl" / "poi_generated.vh"

FRAC_BITS = 56
WIDTH = 64
SCALE = 1 << FRAC_BITS
MAX_VAL = (1 << (WIDTH - 1)) - 1
MIN_VAL = -(1 << (WIDTH - 1))

# Packed-word layout.  THE single definition: the generated header exports
# these as `define POI_*_LSB / POI_*_W and the RTL slices with them, so a
# layout change here cannot silently diverge from auto_zoom.v/text_overlay.v.
POI_MAXIT_LSB, POI_MAXIT_W = 0, 12
POI_ZINT_LSB,  POI_ZINT_W  = 12, 5
POI_ZX10_LSB,  POI_ZX10_W  = 17, 10
POI_CY_LSB                 = 27            # WIDTH bits
POI_CX_LSB                 = 27 + WIDTH    # 91
POI_TABLE_W                = POI_CX_LSB + WIDTH   # 155
POI_NAME_CHARS             = 20
POI_NAME_LABEL_W           = POI_NAME_CHARS * 8   # 160
POI_NAME_LEN_LSB, POI_NAME_LEN_W = POI_NAME_LABEL_W, 5
POI_NAME_W                 = POI_NAME_LEN_LSB + POI_NAME_LEN_W   # 165


def to_8_56(x: float) -> int:
    """Decimal -> signed 64-bit two's complement int representing 8.56 fixed."""
    raw = int(round(x * SCALE))
    if raw > MAX_VAL or raw < MIN_VAL:
        raise ValueError(f"value {x} out of 8.56 range")
    if raw < 0:
        raw += 1 << WIDTH
    return raw


def from_8_56(u: int) -> float:
    if u & (1 << (WIDTH - 1)):
        u -= 1 << WIDTH
    return u / SCALE


def hex64(u: int) -> str:
    return f"64'sh{u:016X}"


def name_to_overlay(s: str, length: int = 20) -> str:
    """Pad/truncate to exactly `length` chars, uppercase, ASCII-safe."""
    s = re.sub(r"[^A-Za-z0-9 \-]", "", s).upper()
    if len(s) > length:
        s = s[:length]
    return s.ljust(length)


def pack_poi(cx_u: int, cy_u: int, zoom_x10: int, zoom_int: int, max_iter: int) -> int:
    assert 0 <= zoom_x10 < (1 << POI_ZX10_W) and 0 <= zoom_int < (1 << POI_ZINT_W) \
        and 0 <= max_iter < (1 << POI_MAXIT_W)
    return ((cx_u << POI_CX_LSB) | (cy_u << POI_CY_LSB) | (zoom_x10 << POI_ZX10_LSB)
            | (zoom_int << POI_ZINT_LSB) | max_iter)


def main():
    if not MASTER_JSON.exists():
        print(f"ERROR: {MASTER_JSON} not found.", file=sys.stderr)
        sys.exit(1)
    with open(MASTER_JSON) as f:
        pois = json.load(f)
    n = len(pois)
    idx_bits = max(5, (n - 1).bit_length())
    print(f"Encoding {n} POIs (idx_bits={idx_bits})")

    # Verification
    print(f"\n{'idx':>3} {'name':<22} {'cx':>14} {'cy':>14} zoom  cx_hex                 cy_hex")
    print("-" * 110)
    encoded = []
    for i, p in enumerate(pois):
        cx, cy = float(p["cx"]), float(p["cy"])
        zoom = float(p["zoom_level"])
        name = p["name"]
        cx_u = to_8_56(cx)
        cy_u = to_8_56(cy)
        cx_back = from_8_56(cx_u)
        cy_back = from_8_56(cy_u)
        err = max(abs(cx - cx_back), abs(cy - cy_back))
        if err > 1e-14:
            print(f"  WARN idx {i}: roundtrip error {err:.2e}")
        zoom_x10 = int(round(zoom * 10))
        # Per-POI max_iter override; falls back to zoom-tier ladder
        # (same thresholds as fractal_top.v auto_max_iter).
        if "max_iter" in p:
            mi = int(p["max_iter"])
        elif zoom < 6:  mi = 512
        elif zoom < 12: mi = 1024
        elif zoom < 18: mi = 2048
        else:           mi = 4095
        encoded.append({
            "idx": i,
            "name": name,
            "cx_u": cx_u,
            "cy_u": cy_u,
            "zoom_x10": zoom_x10,
            "max_iter": mi,
            "overlay": name_to_overlay(name),
        })
        print(f"{i:>3} {name:<22} {cx:>14.10f} {cy:>14.10f} {zoom:5.2f}  {hex64(cx_u)}  {hex64(cy_u)}")

    # Generate Verilog — block-RAM init tables (M10K), not case-statement LUT
    # ROMs.  Depth is the full 2^idx_bits so every address is defined; unused
    # slots get the legacy default entry (view at -0.1875+0i, zoom 8, 1024 it).
    #
    # POI_TABLE_INIT packs one 155-bit word per POI, consumed by auto_zoom.v:
    #   [154:91] cx (8.56)   [90:27] cy (8.56)   [26:17] zoom_x10
    #   [16:12]  zoom_int    [11:0]  max_iter
    # POI_NAME_INIT packs {len[164:160], label[159:0]} — the 20-char overlay
    # label (first char in the MSBs, string-literal layout) plus its
    # PRECOMPUTED trailing-space-stripped length. The length used to be a
    # 20-byte priority scan in text_overlay.v (poi_length_calc); computed in
    # hardware from a register it blew the compose-stage budget by ~0.9 ns
    # (third BRAM build, 2026-07-12), so the encoder now bakes it in.
    depth = 1 << idx_bits
    default_word = pack_poi(to_8_56(-0.1875), to_8_56(0.0), 80, 8, 1024)
    default_name = int.from_bytes(b" " * 20, "big")  # len 0, blank label

    lines = []
    lines.append(f"// AUTO-GENERATED by tools/poi_encode.py — do not edit by hand.")
    lines.append(f"// Source: tools/poi_master.json ({n} POIs, idx_bits={idx_bits}, rom depth={depth})")
    lines.append(f"")
    lines.append(f"`define POI_N_TARGETS  {n}")
    lines.append(f"`define POI_IDX_BITS   {idx_bits}")
    lines.append(f"`define POI_LAST_IDX   {idx_bits}'d{n-1}")
    lines.append("")
    lines.append("// Packed-word layout (LSB offsets / widths) — slice with these, never literals.")
    lines.append(f"`define POI_TABLE_W       {POI_TABLE_W}")
    lines.append(f"`define POI_CX_LSB        {POI_CX_LSB}")
    lines.append(f"`define POI_CY_LSB        {POI_CY_LSB}")
    lines.append(f"`define POI_ZX10_LSB      {POI_ZX10_LSB}")
    lines.append(f"`define POI_ZINT_LSB      {POI_ZINT_LSB}")
    lines.append(f"`define POI_MAXIT_LSB     {POI_MAXIT_LSB}")
    lines.append(f"`define POI_NAME_W        {POI_NAME_W}")
    lines.append(f"`define POI_NAME_LABEL_W  {POI_NAME_LABEL_W}")
    lines.append(f"`define POI_NAME_LEN_LSB  {POI_NAME_LEN_LSB}")
    lines.append("")
    lines.append("// ---- poi_rom init (auto_zoom.v): {cx, cy, zoom_x10, zoom_int, max_iter} ----")
    lines.append("`define POI_TABLE_INIT \\")
    for i in range(depth):
        if i < n:
            e = encoded[i]
            zint = max(0, min(31, int(round(e["zoom_x10"] / 10.0))))
            word = pack_poi(e["cx_u"], e["cy_u"], e["zoom_x10"], zint, e["max_iter"])
            comment = e["name"]
        else:
            word = default_word
            comment = "unused (default)"
        lines.append(f"    poi_rom[{i:<3}] = {POI_TABLE_W}'h{word:0{(POI_TABLE_W+3)//4}X}; /* {comment} */ \\")
    lines[-1] = lines[-1].rstrip(" \\")
    lines.append("")
    lines.append("// ---- name_rom init (text_overlay.v): {len, 20-char overlay label} ----")
    lines.append("`define POI_NAME_INIT \\")
    for i in range(depth):
        if i < n:
            e = encoded[i]
            name_len = len(e["overlay"].rstrip(" "))
            word = (name_len << POI_NAME_LEN_LSB) | int.from_bytes(e["overlay"].encode("ascii"), "big")
            comment = f"{e['name']} (len {name_len})"
        else:
            word = default_name
            comment = "unused (blank, len 0)"
        lines.append(f"    name_rom[{i:<3}] = {POI_NAME_W}'h{word:0{(POI_NAME_W+3)//4}X}; /* {comment} */ \\")
    lines[-1] = lines[-1].rstrip(" \\")

    with open(OUT_VH, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"\nWrote {OUT_VH} ({len(lines)} lines)")


if __name__ == "__main__":
    main()
