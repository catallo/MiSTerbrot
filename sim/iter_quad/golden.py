#!/usr/bin/env python3
"""Software reference for iter_quad.v's Mandelbrot iteration.

Computes the same iter_count + escaped result the FPGA produces, using
matching 64-bit signed 8.56 fixed-point arithmetic and the truncated
64×64 multiply (low×low term skipped — see rtl/mul_trunc64.v).

Use cases:
  1. Generate `expected_iter` values for tb_iter_quad.cpp test cases.
  2. Sweep many (cr, ci) points and diff Python vs Verilator output to
     find precision regressions in the iterator math.

Usage:
  python3 golden.py --cr -0.745 --ci 0.113 --max 500
  python3 golden.py --case origin
  python3 golden.py --gen-cases   # print C++ table for tb_iter_quad.cpp
"""

import argparse


SCALE = 1 << 56   # 8.56 fixed point
WIDTH = 64
MASK64 = (1 << 64) - 1
SIGN64 = 1 << 63


def to_8_56(v: float) -> int:
    """Convert float -> signed 8.56 fixed-point as a Python int."""
    raw = int(round(v * SCALE))
    if raw < 0:
        raw += 1 << 64
    return raw & MASK64


def from_8_56(raw: int) -> float:
    """Convert signed 8.56 (as raw uint64) back to float."""
    if raw & SIGN64:
        raw -= 1 << 64
    return raw / SCALE


def mul_trunc64(a_raw: int, b_raw: int) -> int:
    """Truncated 64×64 fixed-point multiply matching rtl/mul_trunc64.v.

    Inputs/output are signed 8.56 stored as uint64 two's complement.
    Skips the a_lo * b_lo product (only affects bits [63:0]; we extract
    bits [119:56], so only sub-LSB precision is lost).
    """
    sign_a = (a_raw >> 63) & 1
    sign_b = (b_raw >> 63) & 1
    sign_r = sign_a ^ sign_b

    abs_a = ((~a_raw + 1) & MASK64) if sign_a else a_raw
    abs_b = ((~b_raw + 1) & MASK64) if sign_b else b_raw

    a_hi = (abs_a >> 32) & 0xFFFFFFFF
    a_lo = abs_a & 0xFFFFFFFF
    b_hi = (abs_b >> 32) & 0xFFFFFFFF
    b_lo = abs_b & 0xFFFFFFFF

    pp_hh = a_hi * b_hi
    pp_hl = a_hi * b_lo
    pp_lh = a_lo * b_hi
    # SKIP pp_ll = a_lo * b_lo  — truncation, < 2^-24 relative error

    # Reassemble: pp_hh << 64 + (pp_hl + pp_lh) << 32  (full 128-bit product)
    full = (pp_hh << 64) + ((pp_hl + pp_lh) << 32)

    # Extract bits [119:56] (the 8.56 result window)
    abs_result = (full >> 56) & MASK64

    if sign_r:
        return ((~abs_result + 1) & MASK64)
    return abs_result


def add_8_56(a: int, b: int) -> int:
    """Signed 8.56 add with two's complement wrap."""
    return (a + b) & MASK64


def sub_8_56(a: int, b: int) -> int:
    return (a - b) & MASK64


def is_negative(v: int) -> bool:
    return bool(v & SIGN64)


# Constants in 8.56 fixed point (match the localparams in iter_quad.v)
ESCAPE_THRESHOLD = 4 << 56                    # |z|^2 > 4
QUARTER_FIXED    = 1 << (56 - 2)              # 0.25
ONE_FIXED        = 1 << 56
BULB_THRESHOLD   = 1 << (56 - 4)              # 1/16

# A3: period-3 bulb prechecks.  The two large period-3 bulbs attached to
# the upper/lower 1/3 limbs of the main cardioid have super-attracting
# centers (-0.1225611669, ±0.7448617666) — non-real roots of
# c^3 + 2c^2 + c + 1 = 0.  By symmetry across the real axis, one test
# with |ci| catches both bulbs:
#     (cr - P3_CX)^2 + (|ci| - P3_CY)^2  <  P3_R_SQ
# Inscribed-circle radius r = 0.075 (r^2 = 0.005625) chosen so the
# period-3 multiplier max ~0.81 inside the circle — comfortably inside
# the bulb, no risk of false positives.
P3_CX_FIXED      = to_8_56(-0.1225611669)  # uint64 two's-complement of signed 8.56
P3_CY_FIXED      = to_8_56(0.7448617666)
P3_R_SQ_FIXED    = to_8_56(0.005625)


def cardioid_precheck(cr_raw: int, ci_raw: int) -> bool:
    """Main-cardioid interior test: (cr - 0.25)^2 + ci^2 < ... etc.

    Approximation matching iter_quad's S_PREP_Q + S_CARDIOID states:
      q  = (cr - 0.25)^2 + ci^2
      q*(q + (cr - 0.25))  <  0.25 * ci^2

    Returns True if (cr, ci) is in the main cardioid.
    """
    cr_minus_q = sub_8_56(cr_raw, QUARTER_FIXED)
    cr_minus_q_sq = mul_trunc64(cr_minus_q, cr_minus_q)
    ci_sq         = mul_trunc64(ci_raw, ci_raw)
    q             = add_8_56(cr_minus_q_sq, ci_sq)
    inner         = add_8_56(q, cr_minus_q)
    lhs           = mul_trunc64(q, inner)
    rhs           = mul_trunc64(QUARTER_FIXED, ci_sq)
    diff          = sub_8_56(lhs, rhs)
    return is_negative(diff)


def bulb_precheck(cr_raw: int, ci_raw: int) -> bool:
    """Period-2 bulb interior test: (cr + 1)^2 + ci^2 < 1/16."""
    cr_plus_one    = add_8_56(cr_raw, ONE_FIXED)
    cr_plus_one_sq = mul_trunc64(cr_plus_one, cr_plus_one)
    ci_sq          = mul_trunc64(ci_raw, ci_raw)
    sum_sq         = add_8_56(cr_plus_one_sq, ci_sq)
    diff           = sub_8_56(sum_sq, BULB_THRESHOLD)
    return is_negative(diff)


def abs_8_56(v_raw: int) -> int:
    """Absolute value of a signed 8.56 (uint64 two's-complement) — matches
    `c_imag[63] ? -c_imag : c_imag` in the RTL."""
    if v_raw & SIGN64:
        return ((~v_raw + 1) & MASK64)
    return v_raw


def period3_bulb_precheck(cr_raw: int, ci_raw: int) -> bool:
    """A3: period-3 bulb interior test, both upper and lower via |ci|.

        (cr - P3_CX)^2 + (|ci| - P3_CY)^2  <  P3_R_SQ

    Uses the same truncated multiply as the other prechecks so the FPGA
    and golden agree bit-for-bit.
    """
    dr           = sub_8_56(cr_raw, P3_CX_FIXED)
    dr_sq        = mul_trunc64(dr, dr)
    abs_ci       = abs_8_56(ci_raw)
    di           = sub_8_56(abs_ci, P3_CY_FIXED)
    di_sq        = mul_trunc64(di, di)
    sum_sq       = add_8_56(dr_sq, di_sq)
    diff         = sub_8_56(sum_sq, P3_R_SQ_FIXED)
    return is_negative(diff)


def iter_quad_golden(cr: float, ci: float, max_iter: int) -> tuple[int, bool]:
    """Reference implementation matching rtl/iter_quad.v's Mandelbrot path.

    Returns (iter_count, escaped) — same semantics as the Verilator outputs.
    """
    cr_raw = to_8_56(cr)
    ci_raw = to_8_56(ci)

    # Interior precheck — return max_iter without iterating
    if (cardioid_precheck(cr_raw, ci_raw)
            or bulb_precheck(cr_raw, ci_raw)
            or period3_bulb_precheck(cr_raw, ci_raw)):
        return (max_iter, False)

    zr_raw = 0
    zi_raw = 0
    for n in range(1, max_iter + 1):
        zr_sq = mul_trunc64(zr_raw, zr_raw)
        zi_sq = mul_trunc64(zi_raw, zi_raw)
        zr_zi = mul_trunc64(zr_raw, zi_raw)

        mag_sq = add_8_56(zr_sq, zi_sq)

        # Escape test: |z|^2 > 4
        if not is_negative(sub_8_56(mag_sq, ESCAPE_THRESHOLD)):
            return (n, True)

        new_zr = add_8_56(sub_8_56(zr_sq, zi_sq), cr_raw)
        # zi := 2*zr*zi + ci  (2*zr*zi = zr_zi + zr_zi)
        two_zr_zi = add_8_56(zr_zi, zr_zi)
        new_zi    = add_8_56(two_zr_zi, ci_raw)

        zr_raw = new_zr
        zi_raw = new_zi

    return (max_iter, False)


CASES = {
    # Interior / precheck cases
    "origin":         (0.0,    0.0,   100),
    "cardioid_-0.25": (-0.25,  0.0,   100),
    "p2_bulb_-1":     (-1.0,   0.0,   100),
    "near_cusp":      (0.249,  0.0,   500),
    "p3_island":      (-1.75,  0.0,   500),

    # A3: period-3 bulb prechecks (upper + lower bulb via |ci|)
    "p3b_upper_ctr":  (-0.1225611669,  0.7448617666, 100),  # super-attracting center
    "p3b_lower_ctr":  (-0.1225611669, -0.7448617666, 100),  # mirror
    "p3b_inside_x":   (-0.07,          0.7448617666, 100),  # inside circle, +x
    "p3b_inside_y":   (-0.1225611669,  0.79,         100),  # inside circle, +y
    "p3b_inside_diag":(-0.085,         0.78,         100),  # inside circle, diagonal
    # Just outside the inscribed circle (still M-set interior, but precheck shouldn't fire)
    "p3b_outside_circ":(-0.05,         0.7448617666, 500),
    # Outside the bulb entirely (escapes)
    "p3b_far_above":  (-0.1225611669,  0.95,         500),

    # Escape cases at varied depths — used to characterise the
    # RTL-vs-golden iter_count gap.  Probed via boundary scans; the
    # exact `c` values are arbitrary, only the depth distribution
    # matters.
    "escape_2":       (2.0,    0.0,   100),  # ~iter 2-3 (very shallow)
    "escape_1":       (1.0,    0.0,   100),  # ~iter 3
    "esc_d13":        (0.30,   0.0,   500),  # ~iter 13
    "esc_d21":        (0.27,   0.0,   500),  # ~iter 21
    "esc_d31":        (0.26,   0.0,   500),  # ~iter 31
    "esc_d52":        (-0.235, 0.74,  500),  # ~iter 52  (elephant valley)
    "esc_d99":        (-0.745, 0.10,  500),  # ~iter 99  (seahorse area)
    "seahorse_edge":  (-0.745, 0.113, 500),  # ~iter 128 (original off-by-one)
    "esc_d386":       (-0.745, 0.110, 500),  # ~iter 386 (deep seahorse)
    "esc_d461":       (-0.746, 0.115, 500),  # ~iter 461 (deepest sampled)
}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cr", type=float)
    p.add_argument("--ci", type=float)
    p.add_argument("--max", type=int, default=100, dest="max_iter")
    p.add_argument("--case", choices=list(CASES))
    p.add_argument("--gen-cases", action="store_true",
                   help="Print expected values for all CASES — paste into tb_iter_quad.cpp")
    args = p.parse_args()

    if args.gen_cases:
        print("// Auto-generated expected values from sim/iter_quad/golden.py")
        for name, (cr, ci, mx) in CASES.items():
            it, esc = iter_quad_golden(cr, ci, mx)
            print(f'    {{"{name}", {cr:>7}, {ci:>7}, {mx:>4}, {it:>4}, {1 if esc else 0}}},')
        return

    if args.case:
        cr, ci, mx = CASES[args.case]
        name = args.case
    elif args.cr is not None and args.ci is not None:
        cr, ci, mx = args.cr, args.ci, args.max_iter
        name = f"({cr},{ci})"
    else:
        p.error("provide --case NAME or --cr/--ci")

    it, esc = iter_quad_golden(cr, ci, mx)
    print(f"{name:<20} cr={cr:+9.5f} ci={ci:+9.5f} max={mx:4d}  ->  iter={it:4d} escaped={int(esc)}")


if __name__ == "__main__":
    main()
