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

8 test cases, 7 RTL == golden, 1 off-by-one. The off-by-one is a known
disagreement between the FSM's escape-check ordering and the Python
reference — investigated when iterator math next gets touched.

| case | RTL `iter` | golden `iter` |
|---|---:|---:|
| origin (precheck → max_iter) | 100 | 100 |
| cardioid_-0.25 (precheck) | 100 | 100 |
| p2_bulb_-1 (precheck) | 100 | 100 |
| escape_2 | 2 | 2 |
| escape_1 | 3 | 3 |
| near_cusp | 500 (max) | 500 (max) |
| p3_island | 500 (max) | 500 (max) |
| seahorse_edge | **127** | **128** |

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
