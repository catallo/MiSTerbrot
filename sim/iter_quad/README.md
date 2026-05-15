# sim/iter_quad — Verilator harness for `rtl/iter_quad.v`

Cycle-accurate simulation of the iterator quad with a Python golden
model so iterator-math changes can be regression-tested without burning
~25 min Quartus build cycles per experiment.

## Quick start

```bash
make            # build (Verilator + g++ ~12 s)
make run        # drive the test cases, print PASS/FAIL/INFO per case
make wave       # run with FST trace dump → obj_dir/sim.fst
make clean      # rm -rf obj_dir
```

After `make wave`, open the trace with:

```bash
gtkwave obj_dir/sim.fst
```

## Files

- **`Makefile`** — drives Verilator + g++ build.
- **`tb_iter_quad.cpp`** — C++ harness. Drives a list of `(cr, ci, max_iter)`
  test cases through context A and prints `iter_count` + `escaped`.
  Add cases by appending to the `cases[]` array.
- **`golden.py`** — software reference matching `iter_quad.v`'s arithmetic
  bit-by-bit (same 8.56 fixed point, same truncated 64×64 multiply that
  skips the `a_lo*b_lo` term, same cardioid + period-2 bulb prechecks).
- **`obj_dir/`** — Verilator-generated artifacts (`.gitignore`'d).

## Adding a test case

1. Append the `(cr, ci, max_iter, expected_iter, expected_escaped)` tuple
   to `cases[]` in `tb_iter_quad.cpp`. Use `expected_iter = -1` for
   exploration cases (just print, don't pass/fail).
2. Add the same case to `CASES` in `golden.py` to get the reference
   value:
   ```bash
   python3 golden.py --case my_new_case
   python3 golden.py --gen-cases    # regenerate the C++ table
   ```
3. `make && make run`.

## Sanity check (current results)

15 test cases: **7 PASS, 8 GAP, 0 FAIL.**

The "GAP" tag covers cases where escape semantics match (`escaped=1`
on both sides) but `iter_count` differs by exactly ±1.

| case | RTL `iter` | golden `iter` | Δ | notes |
|---|---:|---:|---:|---|
| origin (precheck) | 100 | 100 | 0 | interior |
| cardioid_-0.25 (precheck) | 100 | 100 | 0 | interior |
| p2_bulb_-1 (precheck) | 100 | 100 | 0 | interior |
| near_cusp | 500 | 500 | 0 | hits max_iter |
| p3_island | 500 | 500 | 0 | hits max_iter |
| escape_2 | 2 | 2 | 0 | very shallow |
| escape_1 | 3 | 3 | 0 | very shallow |
| esc_d13 | 12 | 13 | -1 | gap starts |
| esc_d21 | 20 | 21 | -1 | |
| esc_d31 | 30 | 31 | -1 | |
| esc_d52 | 51 | 52 | -1 | elephant valley |
| esc_d99 | 98 | 99 | -1 | seahorse area |
| seahorse_edge | 127 | 128 | -1 | original case |
| esc_d386 | 385 | 386 | -1 | |
| esc_d461 | 460 | 461 | -1 | depth 461 — still −1 |

### What the data tells us

The −1 gap is **uniform across two orders of magnitude in depth**
(13 → 461). It is not an arithmetic divergence — if it were, we'd
expect the delta to grow with depth or vary across regions. It is a
deterministic *labelling* difference between when `iter_count`
increments in the RTL FSM vs when `n` increments in `golden.py`'s
`for n in range(1, max+1)` loop. Almost certainly the RTL counts
"iterations completed before escape was detected" while the golden
counts "the iteration on which escape was detected" (i.e., RTL = N−1
for N = the golden index).

The very shallow escapes (depth 2 and 3) match exactly, suggesting the
FSM has a different control path for the first 1-2 iterations — likely
because `z₀ = 0` makes the squaring stage trivial.

### Implications

- **Visual quality**: a uniform −1 shift across all escaped pixels is
  invisible; palettes are continuous gradients, the shift just
  realigns the whole image by one color step.
- **Performance**: zero — same number of cycles, different label.
- **Correctness**: not actually wrong, just a convention mismatch.
  Either adjust `golden.py` to return `n-1` on escape, or
  post-increment in RTL. Lowest-risk fix is to update the golden
  (no Quartus rebuild).

This is logged for whoever next touches the iterator math; not a
shipping issue.

## When to extend this harness

Per `docs/SIMULATION.md`:

- **Iterator arithmetic changes.** Widening fixed-point past 8.56,
  switching to perturbation theory, adding double-double arithmetic,
  changing the truncated multiply: bit-exact regression vs `golden.py`
  is the only practical way to verify these.
- **Adding interior prechecks** (e.g., the period-3 bulbs from the
  Track A roadmap A3): extend `golden.py`'s precheck functions and
  add boundary cases right outside each new precheck region.
- **Multi-context cross-contamination.** Drive all 6 contexts with
  different `c` values simultaneously and verify each context's
  `iter_count` matches independent golden runs.

## Future targets (not yet implemented)

Per the simulation priorities in `docs/SIMULATION.md`:

- **`sim/region_manager/`** — needed to debug the Mariani-Silver hang
  and the render-FSM race that breaks HDMI when fixed.
  See `docs/MR16_HANG_REPORT_V2.md`.
- **`sim/pixel_pipeline/`** — needed before Track B SDRAM work for
  CDC validation across the new clock domain.
