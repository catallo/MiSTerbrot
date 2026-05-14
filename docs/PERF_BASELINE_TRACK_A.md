# Track A Performance Log

Running record of the Track A frame-rate effort. Each entry is a benchmark
suite run on real hardware, capturing F10 (frames in the last 10 s, sampled
from the pixel-telemetry strip) for every scene in `tools/benchmarks.json`.

**We keep every run in this file — never overwrite an earlier baseline.** The
point is to watch the curve, not just the latest number. Add new entries at
the top; older runs stay below as context for the next optimisation. Treat
this file as the optimisation changelog: one section per build that moved
the needle (or didn't), each with its bitstream hash + build settings so the
numbers stay attributable.

Decode screenshots with `tools/bench_decode_screenshot.py`; run the suite
with `tools/bench_run.py --label <name> --output <path>`; diff two runs
with `tools/bench_diff.py <before.json> <after.json>`.

> **F10 ceiling — permanent (since 2026-05-14).** The render-state machine
> waits for vblank between frames in benchmark mode, capping F10 at ~596
> (~60 fps). An earlier build (commit ff02c4a) bypassed vsync to measure raw
> compute, but the bypass broke the MiSTer HDMI scaler and the on-disk
> screenshot capture (both lock to the framebuffer's vsync edge — the analog
> video board kept working because it bypasses the scaler entirely). Without
> screenshots we can't decode F10 → bench automation dies. The bypass is
> **gone for good**. F10=596 on a fast scene means "≥60 fps"; the few scenes
> faster than 60 fps don't need precise measurement anyway.

---

## 2026-05-14 · `86poi-vsync-clean` — Full 86-POI catalogue baseline

First sweep over the full 86-POI benchmark catalogue (`gen_full_benchmarks.py`
generated `tools/benchmarks.json` from `tools/poi_master.json`). This is the
**new baseline** for all forthcoming Track A experiments — `bench_diff.py`
should compare against this run, not the prior 10-scene tables below.

Driver: `bench_run.py` via misterclaw `input type B/V`. The cfg-write
workaround (`bench_sweep.py`) was deleted in the same commit; it had only
existed because:

1. The V-key didn't actually work due to a runtime mux that overrode the
   counter (fixed in this build — `benchmark_idx` is a plain register now)
2. Bench mode bypassed vsync, which broke the MiSTer HDMI scaler and
   screenshot capture (also reverted in this build — vsync respected;
   F10 capped at ~596 / 60 fps which is fine in practice)

Build:

- Core: `MiSTerbrot_20260514.rbf`
- Bitstream SHA256: `f39c8684f94d9989bf8459f39debb70bace3cbfba7ba1e4372bdebe3e8fdfcfe`
- Quartus seed: `9` · `ROUTER_EFFORT_MULTIPLIER 4.0` · `MISTER_DISABLE_ALSA=1`
- Iter clock: `100 MHz` · setup slack `+0.126 ns`
- ALMs: `34,715 / 41,910 (83%)` · DSPs: `112/112` · BRAM: `83%`
- Results JSON: `tools/benchmark_results_86poi.json`
- MS = Off, MR = 16 (defaults — sweep done without MS optimization)

**Aggregate stats** (86 scenes, 0 decode failures):

| metric | value |
|---|---:|
| min FPS | 0.8 (SAT DBL SPIRAL, z25) |
| max FPS | 59.7 (MISIUREWICZ M4, vsync-capped) |
| median FPS | 14.8 |
| geomean FPS | 10.9 |
| ≥30 fps scenes | 4 (vsync-capped antenna-region POIs) |
| <1 fps scenes | 1 |

**Per-POI numbers** (F10 = frames in last 10 s; FPS = F10/10):

| ID | Scene | F10 | FPS |
|---:|---|---:|---:|
| 0 | P6 SUB BULB | 299 | 29.9 |
| 1 | P3 ISLAND | 298 | 29.8 |
| 2 | P3 ISLAND TIP | 299 | 29.9 |
| 3 | P4 ISLAND | 298 | 29.8 |
| 4 | P5 ISLAND | 199 | 19.9 |
| 5 | P6 ISLAND | 298 | 29.8 |
| 6 | P7 ISLAND | 199 | 19.9 |
| 7 | P8 ISLAND | 298 | 29.8 |
| 8 | P9 ISLAND | 199 | 19.9 |
| 9 | P11 ISLAND | 149 | 14.9 |
| 10 | P22 ISLAND | 120 | 12.0 |
| 11 | ELEPHANT TRUNK | 299 | 29.9 |
| 12 | ELEPHANT HEADS | 100 | 10.0 |
| 13 | ELEPHANT ISLAND | 32 | 3.2 |
| 14 | ELEPHANT P19 | 149 | 14.9 |
| 15 | ELEPHANT P16 | 150 | 15.0 |
| 16 | SEAHORSE BODY | 74 | 7.4 |
| 17 | SEAHORSE TAIL | 120 | 12.0 |
| 18 | SEAHORSE DEEP | 60 | 6.0 |
| 19 | SEAHORSE TAIL2 | 100 | 10.0 |
| 20 | DOUBLE HOOK | 119 | 11.9 |
| 21 | SH SATELLITE | 43 | 4.3 |
| 22 | SAT ANTENNA | 17 | 1.7 |
| 23 | SAT HEAD | 11 | 1.1 |
| 24 | SAT SEAHORSE | 11 | 1.1 |
| 25 | SAT DBL SPIRAL | 8 | 0.8 |
| 26 | JULIA ISLANDS | 21 | 2.1 |
| 27 | TRIPLE WEST | 50 | 5.0 |
| 28 | TRIPLE DEEP | 60 | 6.0 |
| 29 | FEIGENBAUM | 118 | 11.8 |
| 30 | FEIGENBAUM ZOOM | 67 | 6.7 |
| 31 | FEIGENBAUM DEEP | 28 | 2.8 |
| 32 | GEN FEIGENBAUM | 294 | 29.4 |
| 33 | MISIUREWICZ M4 | 597 | 59.7 |
| 34 | MISIUREWICZ M4-2 | 298 | 29.8 |
| 35 | MISIUREWICZ SPIR | 148 | 14.8 |
| 36 | MISIUREWICZ -1.94 | 596 | 59.6 |
| 37 | MISIUREWICZ -1.84 | 597 | 59.7 |
| 38 | DBL SPIRAL P4 | 298 | 29.8 |
| 39 | SINGLE SPIRAL | 299 | 29.9 |
| 40 | TRIPLE MEDALLION | 119 | 11.9 |
| 41 | DBL SPIRAL ISLE | 86 | 8.6 |
| 42 | TRIPLE ISLE MED | 74 | 7.4 |
| 43 | CAULIFLOWER MED | 149 | 14.9 |
| 44 | EJS CAULI | 199 | 19.9 |
| 45 | EJS DBL SPIRAL | 149 | 14.9 |
| 46 | EJS BRANCH | 199 | 19.9 |
| 47 | EJS NUCLEUS | 13 | 1.3 |
| 48 | LOVE CANAL | 32 | 3.2 |
| 49 | P5 ISLAND DEEP | 100 | 10.0 |
| 50 | ELEPHANT MED | 100 | 10.0 |
| 51 | STARFISH | 120 | 12.0 |
| 52 | M3,1 WAKE 3/7 | 149 | 14.9 |
| 53 | M11,1 WAKE 5/11 | 85 | 8.5 |
| 54 | CONCHA APPROACH | 298 | 29.8 |
| 55 | M7,1 WAKE 1/7 | 149 | 14.9 |
| 56 | SH CUSP DEEP | 20 | 2.0 |
| 57 | EJS PERIOD 44 | 195 | 19.5 |
| 58 | JEWEL BOX | 60 | 6.0 |
| 59 | R2T P6 ISLAND | 35 | 3.5 |
| 60 | SH CUSP FINE | 10 | 1.0 |
| 61 | R2 HALF ISLE | 18 | 1.8 |
| 62 | R2T P7 ISLAND | 290 | 29.0 |
| 63 | SCEPTER MED | 119 | 11.9 |
| 64 | BRANCH MED | 298 | 29.8 |
| 65 | EJS P3 DEEP | 85 | 8.5 |
| 66 | NEEDLE MED | 296 | 29.6 |
| 67 | M3,1 1/3 LIMB TIP | 596 | 59.6 |
| 68 | M_4,2 CASCADE 1 | 299 | 29.9 |
| 69 | M_8,4 CASCADE 2 | 199 | 19.9 |
| 70 | M_16,8 CASCADE 3 | 149 | 14.9 |
| 71 | EJS P47 ALPHA | 149 | 14.9 |
| 72 | EJS P50 BETA | 149 | 14.9 |
| 73 | EJS WAKE 1/4 | 149 | 14.9 |
| 74 | SH SPIRAL CONT | 118 | 11.8 |
| 75 | SH TAIL SPIRAL | 99 | 9.9 |
| 76 | ELEPHANT MED 2 | 148 | 14.8 |
| 77 | R2T 1/2 ISLE STEP | 57 | 5.7 |
| 78 | BEYER STEP 13 | 22 | 2.2 |
| 79 | BEYER STEP 14 | 18 | 1.8 |
| 80 | TRIPLE SPIRAL P4 | 30 | 3.0 |
| 81 | MERCATOR P189 | 145 | 14.5 |
| 82 | MERCATOR P38 | 149 | 14.9 |
| 83 | M(3,3) WAKE 1/3 DP | 299 | 29.9 |
| 84 | M(7,7) WAKE 1/4 DP | 298 | 29.8 |
| 85 | EJS P47 GAMMA | 150 | 15.0 |

---

## 2026-05-13 · `a1-ms-on-fixed` — A1 v1 (Mariani-Silver, sequential)

First Mariani-Silver implementation. Single region in flight, walk boundary,
fill or split. Toggled via OSD "Optimisations → Mariani-Silver". MR=16 fixed
(MIN_REGION_DIM). Bench captured with MS=ON; baseline still vsync-capped.

| ID | Scene | Baseline | a1-ms-on | Delta |
|---:|---|---:|---:|---:|
| 0 | FULL 640 | 59.6 | 29.9 | **-49.8%** |
| 1 | P3 ISLAND | 39.4 | 22.9 | -41.9% |
| 2 | P5 ISLAND DEEP | 22.2 | 15.4 | -30.6% |
| 3 | TRIPLE SPIRAL P4 | 3.0 | 5.5 | **+83.3%** |
| 4 | SEAHORSE TAIL | 9.8 | 10.3 | +5.1% |
| 5 | ELEPHANT ISLAND | 7.8 | 8.1 | +3.8% |
| 6 | FEIGENBAUM DEEP | 2.7 | 2.4 | -11.1% |
| 7 | JEWEL BOX | 5.6 | 4.6 | -17.9% |
| 8 | SH SATELLITE | 5.0 | 4.3 | -14.0% |
| 9 | JULIA ISLANDS | 2.2 | 1.9 | -13.6% |

**Geomean: -14%.** Two clear wins (TRIPLE SPIRAL, JULIA ISLANDS-ish), one big
loss (FULL 640), rest mixed. The implementation is correct (renders match
baseline visually after the phase_d4 + S_DONE bugs were fixed) but the
sequential design starves the iterators between regions, and naive MS biases
toward expensive pixels.

---

## 2026-05-13 · `a1-ms-mr16/32/64/128` — MIN_REGION_DIM sweep

A1.1 added a runtime knob (`Optimisations → Min Region`). Same RBF, four
sweeps at runtime — no rebuild needed. Numbers are FPS with MS=ON.

| Scene | Baseline | MR=16 | MR=32 | MR=64 | MR=128 |
|---|---:|---:|---:|---:|---:|
| FULL 640 | 59.6 | 29.8 | 29.9 | 59.6 | 59.6 |
| P3 ISLAND | 39.4 | 22.8 | 22.8 | 32.1 | 31.8 |
| P5 ISLAND DEEP | 22.2 | 15.4 | 15.4 | 15.4 | 15.4 |
| TRIPLE SPIRAL P4 | 3.0 | **5.4** | 3.7 | 2.8 | 3.0 |
| SEAHORSE TAIL | 9.8 | 10.5 | 10.1 | 10.0 | 10.0 |
| ELEPHANT ISLAND | 7.8 | 7.8 | 7.9 | 7.7 | 7.6 |
| FEIGENBAUM DEEP | 2.7 | 2.3 | 2.6 | 2.7 | 2.7 |
| JEWEL BOX | 5.6 | 4.6 | 5.0 | 5.5 | 5.5 |
| SH SATELLITE | 5.0 | 4.3 | 4.6 | 4.9 | 5.0 |
| JULIA ISLANDS | 2.2 | 3.3 | 3.5 | 3.5 | **3.8** |

**Best-per-scene MR varies wildly** — TRIPLE SPIRAL wants MR=16 (deep
recursion), JULIA ISLANDS wants MR=128 (almost no recursion). No single MR
is best across the bench. This drove the conclusion that MS is a per-scene
optimisation, not a global one.

Caveat: FULL 640 reads 59.6 fps at MR=64+ but that's vsync-capped. The
underlying compute might be much faster (or might match baseline) — we
added vsync bypass to disambiguate (see A1.bench).

---

## 2026-05-13 · `6ctx-postfix` — 6-context iter_quad baseline

First run after the 6-context / operand-input-register refactor closed
timing at 100 MHz and the `phase_d4` writeback gate was restored (initial
6-ctx rev incorrectly gated on a newly-added `phase_d5`, scrambling
per-context writeback by one slot — visible as scattered black dots and
~10× slowdown). This becomes the Track A starting line.

Build:

- Core: `MiSTerbrot_20260513.rbf`
- Bitstream SHA256: `ee75241e43f7d87f0d3f3d4bff1c2d9eadd3544d5123547595c63ecb2f2a20de`
- Quartus seed: `3`
- Iterators: `24` (4 quads × 6 contexts)
- Iter clock: `100 MHz` · setup slack `+0.513 ns`
- Results JSON: `tools/benchmark_results_6ctx_postfix.json`

| ID | Scene | F10 | FPS |
|---:|---|---:|---:|
| 0 | FULL 640 | 596 | 59.6 |
| 1 | P3 ISLAND | 394 | 39.4 |
| 2 | P5 ISLAND DEEP | 222 | 22.2 |
| 3 | TRIPLE SPIRAL P4 | 30 | 3.0 |
| 4 | SEAHORSE TAIL | 98 | 9.8 |
| 5 | ELEPHANT ISLAND | 78 | 7.8 |
| 6 | FEIGENBAUM DEEP | 27 | 2.7 |
| 7 | JEWEL BOX | 56 | 5.6 |
| 8 | SH SATELLITE | 50 | 5.0 |
| 9 | JULIA ISLANDS | 22 | 2.2 |

---

## 2026-05-12 · Pre-refactor baseline (older scene list — not comparable)

Captured before the benchmark scene list was rewritten, so the scenes
below do **not** correspond 1:1 with the current `tools/benchmarks.json`.
Kept for historical reference only.

Build:

- Core: `MiSTerbrot_20260512.rbf`
- Bitstream SHA256: `c18dd551f019ab8c8ff70186a4484086c25040c79be68156955a7997eefad16d`
- Quartus seed: `2`
- Iterators: `20` (4 quads × 5 contexts)
- Iter clock: `100 MHz` · setup slack `+0.093 ns`

| ID | Scene | F10 | FPS |
|---:|---|---:|---:|
| 00 | FULL 320 | 596 | 59.6 |
| 01 | FULL 640 | 596 | 59.6 |
| 02 | CARDIOID | 597 | 59.7 |
| 03 | P2 BULB | 597 | 59.7 |
| 04 | P3 ISLAND | 298 | 29.8 |
| 05 | SEAHORSE | 148 | 14.8 |
| 06 | ELEPHANT MED | 596 | 59.6 |
| 07 | FEIGENBAUM | 28 | 2.8 |
| 08 | SATELLITE | 298 | 29.8 |
| 09 | JULIA ISLES | 297 | 29.7 |

`F10` is frames completed in the last 10 seconds, so sustained FPS is
`F10 / 10`.

---

# Lessons learned from A1 (Mariani-Silver, v1 series)

These insights drove the pivot from "always on, lift everyone" to "per-POI
flag" as the headline UX. They're documented here so future A2/A3/B work
inherits the framing.

### MS doesn't help universally — and the bias has a clean explanation

Mariani-Silver explicitly dispatches the **boundary** of each rectangular
region. The boundary is geometrically nearest the fractal's escape locus,
which is exactly where iter counts are highest. Baseline scans every pixel
including cheap interior (max_iter on a fast cardioid-precheck path) and
cheap deep-exterior (1-50 iters); MS skips those and concentrates on the
expensive subset. So even when fewer pixels are dispatched, total iter
work can go up.

Scenes that win:
- Large uniform-iter interior regions (TRIPLE SPIRAL P4, JULIA ISLANDS,
  some deep-zoom POIs where the cardioid+bulbs dominate the screen).
- Cheap-pixel exterior with one dominant fill color (rare at deep zoom).

Scenes that lose:
- Full Mandelbrot view (FULL 640) — boundary pixels are the most expensive,
  exterior is cheap, MS biases toward the costly subset.
- P3 ISLAND, P5 ISLAND DEEP — similar pattern.

### MIN_REGION_DIM is a per-scene knob, not a global one

The sweep showed the optimal MR varies between 16 (deep recursion catches
narrow level-sets in chaotic regions) and 128 (effectively no recursion;
single top-level fill or full-dispatch). No single value is best across the
bench.

### vsync caps bench reads at 60 fps unless bypassed

The render-state machine waits for vblank between frames. In benchmark
mode this clamps F10 to 596 even if raw render time is well under 16.7 ms.
A1.bench adds a `benchmark_active`-gated bypass so the bench measures raw
compute throughput.

### v1 has a known starvation hazard — pipelining is the v2 fix

Sequential single-region-in-flight: between regions, all 24 iterators
drain to idle while the FSM walks `S_BD_WAIT → S_DECIDE → S_FILL/S_SPLIT`.
A1.2 (4-slot pipelining with region_id tag through `pixel_pipeline.v`)
keeps the iterators fed by overlapping the wait phase of one region with
the dispatch phase of another. Realistic expectation: 1.3-1.5× on slow
scenes, narrower gap on fast scenes — not the 3-5× the ROADMAP originally
claimed, because the boundary-bias ceiling is set by content not by FSM
overhead.

# Plan: per-POI MS flag (A1.4)

Each POI in `tools/poi_master.json` gets a `prefers_ms` field. The render
toggles MS automatically based on the active POI's flag (overrides the
global OSD setting, or the OSD setting becomes "Off / On / Auto"). This
gives us the best of both worlds with zero render-time cost.

To populate the flag empirically, we'll expand the benchmark from 10
scenes to all ~86 POIs (one entry per POI in `tools/benchmarks.json`,
generated from `poi_master.json`), then run two full sweeps (MS off, MS
on) and label each POI based on which setting wins. Expected effort:

1. Generate full `benchmarks.json` from `poi_master.json` (~10 lines Python)
2. Regenerate `rtl/benchmark_generated.vh` via `bench_encode.py`
3. Rebuild once (the scene table is compiled in) — ~25 min
4. Two bench passes: 86 scenes × ~12s ≈ 17 min each
5. Per-POI diff → write back `prefers_ms` flags to `poi_master.json`
6. Wire `prefers_ms` to override the global MS toggle (small RTL change)

After this, the 86-scene benchmark also becomes the regression suite for
A1.3 (boundary caching), A2 (real-axis symmetry), and beyond.

# Roadmap of pending Track A items

- **A1.2** (in flight): 4-slot region pipelining. Build pending.
- **A1.3** (pending): cache parent-boundary iter results so split children
  don't re-iterate shared pixels. Targets the cases where MR=16 currently
  loses to MR=128 (deep recursion overhead).
- **A1.4** (planned): per-POI prefers_ms flag, as above.
- **A2** (pending): real-axis symmetry for `cy ≈ 0` POIs.
- **A3** (pending): period-3 bulb precheck in `iter_quad.v`.
- **A4** (pending): push `clk_iter` 100 → 110 MHz via constraint tightening.
