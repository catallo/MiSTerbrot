# Simulation

Verilator harness setup is in progress. First module covered:

- **`sim/iter_quad/`** — Verilator + C++ testbench + Python golden
  model for `rtl/iter_quad.v`. See `sim/iter_quad/README.md` for usage.
  Currently **39 directed cases: 13 PASS, 9 GAP, 0 FAIL** + 17 INFO
  exploration cases (no expected value, just printed).  The GAPs are
  a documented iter_count off-by-one between the FSM's iter increment
  ordering and golden's 1-indexed convention — uniform −1 shift on
  every escape ≥ depth 13.  Cosmetic (uniform palette shift,
  invisible) and confirmed deterministic; not a bug.
- A3 (period-3 bulb precheck) added to both golden.py and the
  testbench; 5 new "inside the inscribed circle" cases all hit the
  precheck (RTL == golden, no GAP).
- **cy=0 deep-zoom exploration cases** (2026-05-18): 17 INFO-tagged
  cases probing MERCATOR P189 / P38 / EJS CAULI coords at varying ci
  magnitudes.  Drove the discovery + fix of the negative-square
  truncation bug in iter_quad's escape detection (see
  `tb_debug.cpp` for the cycle-accurate single-pixel trace).
- **`sim/iter_quad/sim_frame.py`** — full-frame joint sim
  (coord_generator + iter_quad + A2 mirror + framebuffer) in pure
  Python.  Renders a complete frame using the same 8.56 fixed-point
  + truncated multiply as the RTL, outputs a PNG via the XTC palette
  (with 6-bit mask).  Used to A/B test "does the bug live in the
  modelled logic or in HW-specific timing".
- **`sim/iter_quad/probe_cy0.py` and `probe_2d.py`** — bit-exact
  golden vs `mpmath`@200-bit reference probes for the cy=0 deep-zoom
  POIs.  Confirmed iter_quad math (golden) is correct to 200-bit
  precision — narrowing the bug to RTL HW behaviour and triggering
  the cycle-accurate `tb_debug.cpp` investigation.
- **`sim/iter_quad/tb_debug.cpp`** — focused cycle-accurate single-pixel
  trace.  Prints `ctx_state[0]`, `ctx_iter`, `ctx_iter_count`,
  `phase_d4`, `escape_pl`, `mag_sq_w/_r`, `zr_sq`, `zi_sq`, `zr_sq_ovf`,
  `zi_sq_ovf`, and raw `zi_sq_raw` hex each cycle until done.  This
  is the harness that caught the negative-square sign-extension bug
  by showing `zi_sq=-0.0000` with `zi_ovf=0xff` triggering escape at
  cycle 65 → iter=2 + escaped=1.  Build standalone:
  ```
  cd sim/iter_quad
  verilator --cc --exe --build -Wno-fatal --top-module iter_quad \
      --Mdir obj_dir_debug ../../rtl/iter_quad.v ../../rtl/mul_trunc64.v \
      tb_debug.cpp
  ./obj_dir_debug/Viter_quad
  ```

The previous `sim/` directory (Verilator harnesses for `iter_pair.v` and
`mandelbrot_iterator.v`) was removed when those modules were retired during
the iter_quad refactor. The new structure is per-module folders under
`sim/`, each with its own Makefile + harness + golden model.

The rest of this document is a forward-looking brief: **when each
remaining module needs sim, and what each testbench should cover.**

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

### `iter_quad.v` — bit-exact arithmetic regression — **implemented**

See `sim/iter_quad/` (`Makefile`, `tb_iter_quad.cpp`, `golden.py`,
`README.md`). Current coverage:

- 22 directed test cases across 4 categories:
  - 5 interior precheck cases (cardioid, period-2 bulb)
  - 5 A3 period-3 bulb cases (upper + lower centers, inside-circle
    offsets, outside-circle, far-from-bulb escape)
  - 2 very-shallow escapes (escape_1, escape_2)
  - 10 escape cases at varied depths (13, 21, 31, 52, 99, 128, 386,
    461) for characterising the iter_count off-by-one
- Golden model in `golden.py` matches the truncated 64×64 multiply
  bit-by-bit (skips the `a_lo*b_lo` term per `rtl/mul_trunc64.v`)
  AND the cardioid + period-2 + period-3 bulb prechecks.
- 13 PASS, 9 GAP, 0 FAIL.  The GAPs are the deterministic +1 RTL/golden
  offset on escape iter_count for depths ≥ 13 (RTL counts "iterations
  completed before escape detected"; golden counts "iteration on which
  escape was detected").  Cosmetic; uniform palette shift, invisible.

Still TODO on this harness:

- Multi-context concurrency: drive all 6 contexts (A–F) with different
  `c` values simultaneously and verify they don't cross-contaminate.
- POI catalogue regression: sweep canonical POI coords from
  `tools/poi_master.json` at `max_iter ∈ {512, 1024, 2048, 4095}` and
  diff against `tools/poi_render.py` (the Python escape-count
  renderer). Catches precision drift.

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

**Critical for Track B (SDRAM-backed framebuffer + 480p)**: that work
adds a new clock domain for the SDRAM controller, with CDC against both
`clk_sys` and `clk_iter`. CDC bugs there would be intermittent on real
hardware and very hard to root-cause without sim. Build this harness
before starting Track B.

### `region_manager.v` + `fractal_top.v` render FSM — for MS revival

The Mariani-Silver feature was disabled in the shipping core because
of an intermittent hang at MR=16 (and lower rates at MR=64/128).
ChatGPT Pro analysis (`docs/MR16_HANG_CHATGPT_PRO_V2.md`) traced it to
a race in `fractal_top.v`'s render FSM where the bank-swap block
consumes a same-cycle `frame_done_rise` that the render FSM was about
to use to exit `RS_WAIT_SWAP`. The proposed two-line fix removes the
hang on VGA but breaks HDMI scaler synchronization regardless of timing
margin.

A combined `fractal_top` + `region_manager` testbench would let us:
- Reproduce the hang deterministically (one specific clock-edge
  alignment).
- Verify the proposed fix removes it.
- Investigate the HDMI side-effect by simulating arcade_video's HSync /
  VSync / CE_PIXEL outputs and modelling what the scaler expects.
- Add a frame/epoch tag to dispatched coords so stale results from a
  previous region can't be miscounted into the next.

This is the prerequisite for resuming Track A's per-POI `prefers_ms`
work (was A1.4).

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
