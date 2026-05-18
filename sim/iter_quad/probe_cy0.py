#!/usr/bin/env python3
"""Probe iter_quad at deep cy=0 zooms — does it distinguish small ci values?

Picks the MERCATOR coords + step from the catalogue and walks several
rows from the cy=0 axis outward.  For each row, runs the bit-exact
golden model AND an mpmath high-precision reference at the same coords.
If the bit-exact model collapses many rows to the same iter_count while
mpmath gives distinct counts, the iter_quad precision is the limit.
"""

import sys
from pathlib import Path

# Import golden model from this dir
sys.path.insert(0, str(Path(__file__).parent))
from golden import iter_quad_golden

from mpmath import mp, mpf

# Catalogue values (matches tools/poi_master.json)
DEFAULT_STEP = 0.0125  # matches RTL DEFAULT_STEP = 0x0003333333333333 in 8.56

POIS = {
    "MERCATOR P189": dict(cx=-1.7487645202, cy=0.0, z=25.0, max_iter=4095),
    "MERCATOR P38":  dict(cx=-1.7487645763, cy=0.0, z=22.0, max_iter=4095),
    "EJS CAULI":     dict(cx=-1.7487645,    cy=0.0, z=17.34, max_iter=2048),
}

# mpmath ref at 200 bits — way past 8.56's 56-bit precision
mp.prec = 200


def mpmath_iter(cr: float, ci: float, max_iter: int) -> tuple[int, bool]:
    """Reference Mandelbrot iteration in arbitrary precision."""
    c_re = mpf(cr)
    c_im = mpf(ci)
    z_re = mpf(0)
    z_im = mpf(0)
    for n in range(1, max_iter + 1):
        z_re2 = z_re * z_re
        z_im2 = z_im * z_im
        if z_re2 + z_im2 > 4:
            return (n, True)
        new_re = z_re2 - z_im2 + c_re
        new_im = 2 * z_re * z_im + c_im
        z_re, z_im = new_re, new_im
    return (max_iter, False)


def probe(poi_name: str, poi: dict, row_offsets):
    """For each row offset from cy=0 axis, run golden + mpmath. Print diff."""
    step = DEFAULT_STEP / (2 ** poi["z"])
    print(f"\n=== {poi_name}: cx={poi['cx']} cy={poi['cy']} z={poi['z']} step={step:.3e} ===")
    print(f"{'row':>4} {'ci':>14} {'golden':>10} {'mpmath':>10} {'delta'}")
    print("-" * 60)
    prev_golden = None
    for row_off in row_offsets:
        # Row offset from center; half-step shift baked in to match RTL ci_start
        ci = (row_off + 0.5) * step
        g_it, g_esc = iter_quad_golden(poi["cx"], ci, poi["max_iter"])
        m_it, m_esc = mpmath_iter(poi["cx"], ci, poi["max_iter"])
        delta = ""
        if prev_golden is not None and g_it == prev_golden:
            delta += " ←SAME"
        if g_it != m_it:
            delta += f" Δgolden-mpmath={g_it - m_it:+d}"
        print(f"{row_off:>4} {ci:>14.4e} {g_it:>10} {m_it:>10} {delta}")
        prev_golden = g_it


# Walk: row offsets from 0 (= cy=0 axis) outward in row units
ROW_OFFSETS = [0, 1, 2, 5, 10, 20, 40, 60, 80, 100, 119]

for name, poi in POIS.items():
    probe(name, poi, ROW_OFFSETS)
