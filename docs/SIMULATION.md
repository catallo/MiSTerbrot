# Simulation

There is currently no active simulation infrastructure in this project. The
previous `sim/` directory (Verilator harnesses for `iter_pair.v` and
`mandelbrot_iterator.v`) was removed alongside those modules during the
iter_quad refactor.

This document is a forward-looking brief: **when and how to add sim back if
the project ever needs it.**

## When sim becomes worth the setup cost

The core has been changing in "tweak POIs / palettes / overlay" mode, where
the FPGA build-deploy-look-at-screen loop (`tools/poi_walkthrough.py` is the
canonical end-to-end check) catches problems faster than sim development
would. Bring sim back when one of these starts:

- **Iterator arithmetic changes.** Widening fixed-point past 8.56, switching
  to perturbation theory, adding double-double arithmetic, or implementing
  a different fractal formula. Bit-exact correctness against a software
  reference is the only practical way to verify these — visual inspection
  hides subtle math bugs behind palette-cycling noise.
- **CDC boundary changes.** Anything touching the `clk_sys` ↔ `clk_iter`
  toggle synchronisers in `pixel_pipeline.v`, or adding a third clock
  domain. CDC bugs are intermittent on hardware (1-in-a-million) but
  deterministic in sim with controlled clock skew.
- **State-machine refactors.** Adding states to `auto_zoom.v` (new modes,
  multi-press combos), reworking the Fisher-Yates shuffle, changing
  `S_HOLD` semantics. Each transition deserves a directed test.
- **Plans to release a v2.** A regression sweep before tagging is much
  cheaper to run in sim than to redo on the FPGA per change.

## What to cover

### `iter_quad.v` — bit-exact arithmetic regression

This is the most valuable target. Build it first.

- **Harness**: pure-C++ Verilator testbench. Drive `cr`, `ci`, `max_iter` for
  each of the 5 contexts; capture `iter_count` and `escaped` when `done`
  fires.
- **Golden model**: a Python (or C) reference that computes the same
  truncated 64×64 multiply path in software using `int128` or arbitrary
  precision. Compare bit-exactly.
- **Test vectors**:
  - `c = 0`: trivial interior, should return `max_iter`.
  - `c = 2 + 0i`: escapes on iter 1.
  - Boundary points (canonical POI coords) at low/high `max_iter`: expected
    escape count from the Python renderer in `tools/poi_render.py`.
  - Cardioid/bulb precheck points: confirm interior is detected on the
    cardioid (e.g., `c = -0.1 + 0i`) and the period-2 bulb (`c = -1 + 0i`).
  - All 5 contexts running concurrently with different `c` values — verify
    they don't cross-contaminate.

### `auto_zoom.v` — playlist + snap state machine

- **Reset shuffle**: assert the Fisher-Yates shuffle produces a permutation
  (no duplicates, every index visited).
- **Snap mode** (`S_HOLD` / `S_SNAP_LOAD`): pulse `snap_next`, verify
  `step` lands at exactly `DEFAULT_STEP >>> target_zoom_int` and stays
  static; pulse again, verify `target_idx` advances by one playlist slot;
  pulse `enable` low, verify state returns to `S_IDLE`.
- **Skip vs snap**: in `S_ZOOM_IN`, `skip_next` should transition to
  `S_NEXT` (start zoom-in on the next POI), while `snap_next` should
  transition to `S_HOLD` (freeze immediately).

### `pixel_pipeline.v` — CDC + dispatch fairness

- **Toggle synchroniser**: drive `start_x[i]` on `clk_sys`, verify exactly
  one pulse fires on `clk_iter` per request.
- **Slot fairness**: dispatch with N iterators busy and verify round-robin
  collection order matches dispatch order.

## What NOT to cover in sim

- **The video pipeline** (`coord_generator.v`, `framebuffer.v`,
  `color_mapper.v`, `text_overlay.v`, `video_timing.v`). These are
  pixel-stream modules where the meaningful checks are visual — easier to
  verify on the actual FPGA via `tools/poi_walkthrough.py` and
  `misterclaw-send screenshot` than to build pixel-equality testbenches.
- **MiSTer framework integration** (`MiSTerbrot.sv`, `sys/`). Requires real
  hardware to exercise PS/2 input, OSD, HPS interaction.
- **Resource and timing closure**. Only Quartus tells you whether the
  design fits and closes timing; sim says nothing about that.

## Tooling notes

- Use **Verilator** (was the prior choice; mature, fast, easy CI integration).
- Pin a stable version in the testbench Makefile — Verilator's `--trace`
  output format changed across versions and unpinned harnesses rot quickly.
- Put the golden-model reference in `tools/iter_quad_reference.py` so
  changes to the renderer (e.g., a precision tweak) are visible in the
  same commit as the testbench update.
- Don't try to share Verilator code across modules; per-module harnesses
  are simpler than a top-level integration sim and cover most of the value.

## Why this is documented and not done

A clean `iter_quad` testbench against a Python golden model is roughly a
day of work, plus another half-day of building out the golden model. That
is a worthwhile investment when iterator math is in flux, but not while we
are tweaking the POI catalogue or the overlay. The note exists so the next
person who touches arithmetic isn't tempted to skip sim again.
