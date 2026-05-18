#!/usr/bin/env python3
"""2D probe: sweep both cr (columns) and ci (rows) around MERCATOR P189.

Maps the iter_count distribution.  If iter varies across cr but is
~constant across ci near 0, that explains the uniform pink band in the
FPGA capture (the iter math is fine but the visual content is uniform).
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from golden import iter_quad_golden

DEFAULT_STEP = 0.0125
CX = -1.7487645202
Z = 25.0
MAX_ITER = 1024  # what FPGA Auto resolves to with our per-POI override

step = DEFAULT_STEP / (2 ** Z)
step_x = step / 2  # 640-mode pixel pitch

# Sample 8 columns × 8 rows, spread across the visible frame
col_offsets = [-160, -100, -50, -10, 10, 50, 100, 159]  # cr offset in step_x units
row_offsets = [-119, -60, -20, -5, 0, 5, 20, 60]        # ci offset in step units (row 0 = cy axis)

print(f"MERCATOR P189: cx={CX} z={Z} max_iter={MAX_ITER}")
print(f"step={step:.3e}  step_x={step_x:.3e}")
print()
print(f"{'':>8} " + " ".join(f"col{c:+4}" for c in col_offsets))
for ro in row_offsets:
    ci = (ro + 0.5) * step
    line = f"row{ro:+4} "
    for co in col_offsets:
        cr = CX + (co + 0.5) * step_x
        it, _ = iter_quad_golden(cr, ci, MAX_ITER)
        line += f"  {it:>5}"
    print(line)
