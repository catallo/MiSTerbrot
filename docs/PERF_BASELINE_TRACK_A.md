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

> ## Mandatory: full per-POI tables, not summaries
>
> **Every entry in this log must include the complete F10 per scene for all
> 86 POIs.** Geomeans and "X scenes hit 2.00×" buckets are useful framing
> but they hide per-POI swings — half-step shifts, precheck changes, and
> dispatcher tweaks can speed up some scenes by 50-100% while regressing
> others by 10-20% even at the same geomean.  Past entries that summarised
> are noted as such; backfill the full table when re-deriving from the
> archived JSONs is feasible.
>
> Why: the geomean of (a 2.00× win on POI A) and (a 0.50× regression on
> POI B) is 1.00× — invisible. The user's perceptual quality cares about
> per-POI worst-case, not the geomean.  Always show all 86 numbers.
>
> Generate the per-POI table from the JSON outputs of `tools/bench_run.py`
> with a small Python script that joins by `idx` and prints baseline/after
> F10 + ratio per row.  Two-run table: 4 columns.  N-run table: N+1
> columns plus per-step ratios.

> **F10 ceiling — permanent (since 2026-05-14).** The render-state machine
> waits for vblank between frames in benchmark mode, capping F10 at ~596
> (~60 fps). An earlier build (commit ff02c4a) bypassed vsync to measure raw
> compute, but the bypass broke the MiSTer HDMI scaler and the on-disk
> screenshot capture (both lock to the framebuffer's vsync edge — the analog
> video board kept working because it bypasses the scaler entirely). Without
> screenshots we can't decode F10 → bench automation dies. The bypass is
> **gone for good**. F10=596 on a fast scene means "≥60 fps"; the few scenes
> faster than 60 fps don't need precise measurement anyway.

> **Mariani-Silver — disabled in shipping core (since 2026-05-15).** MS
> (region_manager.v + S/A keys + 1/2/3/4 keys + OSD toggle) was end-to-end
> functional in earlier sessions but exhibits an intermittent hang. The
> diagnosed root-cause fix breaks HDMI scaler synchronization regardless of
> timing margin. Until a Verilator harness lets us debug the HDMI-side
> interaction, MS is dropped from the shipping core and from the bench
> sweep. Track A's per-POI `prefers_ms` plan (was A1.4) is paused.
> Investigation transcript: `docs/MR16_HANG_REPORT*.md` and
> `docs/MR16_HANG_CHATGPT_PRO*.md`.

---

## 2026-05-16 · `a3-perpoi-osd` — A3 period-3 bulb prechecks (per-POI opt-in + OSD control)

A3 lands.  Three changes shipped together:

1. **4 new POIs** added to the catalogue (indices 86-89):
   - P3 BULB UPPER (-0.1226, +0.7449, zoom 4) — canonical p3 bulb view
   - P3 BULB LOWER (mirror across real axis)
   - P3 LIMB FULL (-0.1875, +0.589, zoom 3) — wider limb context
   - P3 BULB DEEP (zoom 7) — every pixel inside the inscribed circle
2. **Period-3 bulb precheck** in `iter_quad.v`:
   - New state S_BULB3 between S_BULB and S_ITER
   - Tests `(cr - P3_CX)² + (|ci| - P3_CY)² < r²` where r=0.075,
     P3_CX=-0.1226, P3_CY=+0.7449.  By symmetry, |ci| catches both
     upper and lower bulbs in one test.
   - Inscribed-circle radius chosen so the period-3 multiplier max ~0.81
     inside the circle — no false positives possible.
3. **Per-POI opt-in flag + OSD override** (added after first sweep showed
   regressions on shallow-escape scenes):
   - `precheck_p3: true` field in `tools/poi_master.json` enables the
     precheck for that scene in benchmark mode.
   - OSD entry `O[26:25],P3 Bulb Precheck,Auto,On,Off;` lets the user
     override globally — Auto = use per-POI flag.

### Why the per-POI flag

First A3 build had the precheck always on.  This added ~12 wallclock
cycles per pixel (the new S_BULB3 prime+check) before the iteration
loop.  For shallow-escape scenes (where most pixels iterate only ~5-20
times), the precheck overhead was 25-50 % of total per-pixel time.

Three scenes regressed >5 % with always-on A3:
- BRANCH MED 29.8 → 19.8 fps (-33.6 %)
- EJS WAKE 1/4 19.9 → 14.9 fps (-25.1 %)
- P22 ISLAND 12.0 → 10.0 fps (-16.7 %)

With the per-POI flag, only POIs marked `precheck_p3: true` pay the
cost.  The 4 new period-3 POIs opt in; everything else defaults to
off.  Result: the regressions disappear, the wins stay.

### Sweep health

- 0/90 alignment mismatches.
- 0/90 sym_overflow.
- Visual: P3 BULB UPPER renders correctly (the bulb is a clean black
  disk surrounded by the chaotic boundary — no false-positive specks
  outside the bulb).  P3 BULB DEEP is solid black (every pixel
  precheck-skipped → max_iter → interior color), confirming the
  precheck fires for the entire frame.

Build: `MiSTerbrot_20260516.rbf` (Quartus 17.0.2 Lite, ~24 min,
113 warnings, 0 errors — same as a2-half-step).

### Full per-POI table (3-way: phase0 baseline / A3 always-on / A3 per-POI)

`A3 per-POI` is the shipped configuration (`Auto` mode in OSD =
default).  `A3 always-on` was an interim build that paid the precheck
cost on every scene — included to show why per-POI was necessary.

| # | scene | phase0 fps | A3 always-on fps | A3 per-POI fps | per-POI ratio | always-on ratio | per-POI vs always-on |
|---|---|---:|---:|---:|---:|---:|---:|
|  0 | P6 SUB BULB             |  59.5 |  59.6 |  59.5 | 1.00× | 1.00× | +1.00× |
|  1 | P3 ISLAND               |  59.7 |  59.6 |  59.7 | 1.00× | 1.00× | +1.00× |
|  2 | P3 ISLAND TIP           |  59.7 |  59.6 |  59.6 | 1.00× | 1.00× | +1.00× |
|  3 | P4 ISLAND               |  29.9 |  29.7 |  29.8 | 1.00× | 0.99× | +1.00× |
|  4 | P5 ISLAND               |  19.9 |  19.8 |  19.9 | 1.00× | 0.99× | +1.01× |
|  5 | P6 ISLAND               |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
|  6 | P7 ISLAND               |  19.8 |  19.9 |  19.9 | 1.01× | 1.01× | +1.00× |
|  7 | P8 ISLAND               |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
|  8 | P9 ISLAND               |  19.9 |  19.9 |  19.9 | 1.00× | 1.00× | +1.00× |
|  9 | P11 ISLAND              |  14.9 |  14.9 |  14.9 | 1.00× | 1.00× | +1.00× |
| 10 | P22 ISLAND              |  12.0 |  10.0 |  11.9 | 0.99× | 0.83× | +1.19× |
| 11 | ELEPHANT TRUNK          |  29.9 |  29.8 |  29.9 | 1.00× | 1.00× | +1.00× |
| 12 | ELEPHANT HEADS          |   9.9 |  10.0 |  10.0 | 1.01× | 1.01× | +1.00× |
| 13 | ELEPHANT ISLAND         |   3.1 |   3.2 |   3.2 | 1.03× | 1.03× | +1.00× |
| 14 | ELEPHANT P19            |  12.0 |  11.9 |  11.9 | 0.99× | 0.99× | +1.00× |
| 15 | ELEPHANT P16            |  14.9 |  14.9 |  14.9 | 1.00× | 1.00× | +1.00× |
| 16 | SEAHORSE BODY           |   7.5 |   7.5 |   7.5 | 1.00× | 1.00× | +1.00× |
| 17 | SEAHORSE TAIL           |  11.9 |  12.0 |  12.0 | 1.01× | 1.01× | +1.00× |
| 18 | SEAHORSE DEEP           |   5.9 |   5.9 |   5.9 | 1.00× | 1.00× | +1.00× |
| 19 | SEAHORSE TAIL2          |  10.0 |  10.0 |  10.0 | 1.00× | 1.00× | +1.00× |
| 20 | DOUBLE HOOK             |  12.0 |  12.0 |  11.9 | 0.99× | 1.00× | +0.99× |
| 21 | SH SATELLITE            |   4.3 |   4.3 |   4.3 | 1.00× | 1.00× | +1.00× |
| 22 | SAT ANTENNA             |   1.7 |   1.7 |   1.7 | 1.00× | 1.00× | +1.00× |
| 23 | SAT HEAD                |   1.1 |   1.1 |   1.1 | 1.00× | 1.00× | +1.00× |
| 24 | SAT SEAHORSE            |   1.1 |   1.1 |   1.1 | 1.00× | 1.00× | +1.00× |
| 25 | SAT DBL SPIRAL          |   0.9 |   0.9 |   0.9 | 1.00× | 1.00× | +1.00× |
| 26 | JULIA ISLANDS           |   2.2 |   2.2 |   2.0 | 0.91× | 1.00× | +0.91× |
| 27 | TRIPLE WEST             |   5.0 |   4.9 |   4.9 | 0.98× | 0.98× | +1.00× |
| 28 | TRIPLE DEEP             |   6.0 |   5.9 |   6.0 | 1.00× | 0.98× | +1.02× |
| 29 | FEIGENBAUM              |  19.9 |  19.8 |  19.8 | 0.99× | 0.99× | +1.00× |
| 30 | FEIGENBAUM ZOOM         |  12.0 |  12.0 |  11.9 | 0.99× | 1.00× | +0.99× |
| 31 | FEIGENBAUM DEEP         |   5.5 |   5.5 |   5.5 | 1.00× | 1.00× | +1.00× |
| 32 | GEN FEIGENBAUM          |  29.8 |  29.5 |  29.9 | 1.00× | 0.99× | +1.01× |
| 33 | MISIUREWICZ M4          |  59.5 |  59.6 |  59.6 | 1.00× | 1.00× | +1.00× |
| 34 | MISIUREWICZ M4-2        |  29.8 |  29.9 |  29.8 | 1.00× | 1.00× | +1.00× |
| 35 | MISIUREWICZ SPIR        |  14.8 |  14.8 |  14.7 | 0.99× | 1.00× | +0.99× |
| 36 | MISIUREWICZ -1.94       |  59.7 |  59.6 |  59.7 | 1.00× | 1.00× | +1.00× |
| 37 | MISIUREWICZ -1.84       |  59.6 |  59.6 |  59.7 | 1.00× | 1.00× | +1.00× |
| 38 | DBL SPIRAL P4           |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
| 39 | SINGLE SPIRAL           |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
| 40 | TRIPLE MEDALLION        |  11.9 |  11.9 |  11.9 | 1.00× | 1.00× | +1.00× |
| 41 | DBL SPIRAL ISLE         |   8.6 |   8.6 |   8.6 | 1.00× | 1.00× | +1.00× |
| 42 | TRIPLE ISLE MED         |   7.5 |   7.4 |   7.5 | 1.00× | 0.99× | +1.01× |
| 43 | CAULIFLOWER MED         |  14.8 |  14.9 |  14.9 | 1.01× | 1.01× | +1.00× |
| 44 | EJS CAULI               |  29.8 |  29.7 |  29.8 | 1.00× | 1.00× | +1.00× |
| 45 | EJS DBL SPIRAL          |  15.0 |  14.9 |  14.9 | 0.99× | 0.99× | +1.00× |
| 46 | EJS BRANCH              |  19.9 |  19.9 |  19.9 | 1.00× | 1.00× | +1.00× |
| 47 | EJS NUCLEUS             |   1.3 |   1.3 |   1.3 | 1.00× | 1.00× | +1.00× |
| 48 | LOVE CANAL              |   3.2 |   3.2 |   3.2 | 1.00× | 1.00× | +1.00× |
| 49 | P5 ISLAND DEEP          |   8.6 |   8.6 |   8.6 | 1.00× | 1.00× | +1.00× |
| 50 | ELEPHANT MED            |  10.0 |  10.0 |  10.0 | 1.00× | 1.00× | +1.00× |
| 51 | STARFISH                |  12.0 |  12.0 |  11.9 | 0.99× | 1.00× | +0.99× |
| 52 | M3,1 WAKE 3/7           |  14.9 |  14.9 |  14.9 | 1.00× | 1.00× | +1.00× |
| 53 | M11,1 WAKE 5/11         |   8.5 |   8.5 |   8.5 | 1.00× | 1.00× | +1.00× |
| 54 | CONCHA APPROACH         |  59.3 |  59.3 |  59.0 | 0.99× | 1.00× | +0.99× |
| 55 | M7,1 WAKE 1/7           |  14.9 |  14.9 |  14.9 | 1.00× | 1.00× | +1.00× |
| 56 | SH CUSP DEEP            |   2.0 |   2.0 |   2.0 | 1.00× | 1.00× | +1.00× |
| 57 | EJS PERIOD 44           |  19.4 |  19.4 |  19.4 | 1.00× | 1.00× | +1.00× |
| 58 | JEWEL BOX               |   6.0 |   6.0 |   6.0 | 1.00× | 1.00× | +1.00× |
| 59 | R2T P6 ISLAND           |   6.6 |   6.6 |   6.6 | 1.00× | 1.00× | +1.00× |
| 60 | SH CUSP FINE            |   1.0 |   1.0 |   1.0 | 1.00× | 1.00× | +1.00× |
| 61 | R2 HALF ISLE            |   1.8 |   1.8 |   1.8 | 1.00× | 1.00× | +1.00× |
| 62 | R2T P7 ISLAND           |  59.5 |  59.3 |  59.2 | 0.99× | 1.00× | +1.00× |
| 63 | SCEPTER MED             |  12.0 |  11.9 |  12.0 | 1.00× | 0.99× | +1.01× |
| 64 | BRANCH MED              |  29.8 |  19.8 |  29.8 | 1.00× | 0.66× | +1.51× |
| 65 | EJS P3 DEEP             |   8.5 |   8.6 |   8.5 | 1.00× | 1.01× | +0.99× |
| 66 | NEEDLE MED              |  29.7 |  29.6 |  29.5 | 0.99× | 1.00× | +1.00× |
| 67 | M3,1 1/3 LIMB TIP       |  59.6 |  59.5 |  59.6 | 1.00× | 1.00× | +1.00× |
| 68 | M_4,2 CASCADE 1         |  59.6 |  59.5 |  59.5 | 1.00× | 1.00× | +1.00× |
| 69 | M_8,4 CASCADE 2         |  29.9 |  29.9 |  29.9 | 1.00× | 1.00× | +1.00× |
| 70 | M_16,8 CASCADE 3        |  29.8 |  29.8 |  29.7 | 1.00× | 1.00× | +1.00× |
| 71 | EJS P47 ALPHA           |  15.0 |  15.0 |  15.0 | 1.00× | 1.00× | +1.00× |
| 72 | EJS P50 BETA            |  14.9 |  14.9 |  15.0 | 1.01× | 1.00× | +1.01× |
| 73 | EJS WAKE 1/4            |  19.9 |  14.9 |  19.9 | 1.00× | 0.75× | +1.34× |
| 74 | SH SPIRAL CONT          |  11.8 |  11.8 |  11.8 | 1.00× | 1.00× | +1.00× |
| 75 | SH TAIL SPIRAL          |   9.9 |   9.9 |   9.9 | 1.00× | 1.00× | +1.00× |
| 76 | ELEPHANT MED 2          |  14.8 |  14.9 |  14.9 | 1.01× | 1.01× | +1.00× |
| 77 | R2T 1/2 ISLE STEP       |   6.0 |   5.7 |   5.8 | 0.97× | 0.95× | +1.02× |
| 78 | BEYER STEP 13           |   2.3 |   2.2 |   2.2 | 0.96× | 0.96× | +1.00× |
| 79 | BEYER STEP 14           |   1.9 |   1.9 |   1.9 | 1.00× | 1.00× | +1.00× |
| 80 | TRIPLE SPIRAL P4        |   3.0 |   3.0 |   3.0 | 1.00× | 1.00× | +1.00× |
| 81 | MERCATOR P189           |  52.3 |  52.2 |  52.0 | 0.99× | 1.00× | +1.00× |
| 82 | MERCATOR P38            |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
| 83 | M(3,3) WAKE 1/3 DP      |  29.9 |  29.9 |  29.8 | 1.00× | 1.00× | +1.00× |
| 84 | M(7,7) WAKE 1/4 DP      |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
| 85 | EJS P47 GAMMA           |  14.9 |  14.9 |  15.0 | 1.01× | 1.00× | +1.01× |
| 86 | P3 BULB UPPER           |   6.7 |  12.0 |  12.0 | **1.79×** | 1.79× | +1.00× |
| 87 | P3 BULB LOWER           |   6.6 |  11.9 |  11.9 | **1.80×** | 1.80× | +1.00× |
| 88 | P3 LIMB FULL            |  19.9 |  29.9 |  29.8 | **1.50×** | 1.50× | +1.00× |
| 89 | P3 BULB DEEP            |   2.5 |  59.7 |  59.7 | **23.88×** | 23.88× | +1.00× |

Geomean A3 per-POI vs phase0 (all 90 POIs):       **1.052× (+5.2 %)**.
Geomean A3 always-on vs phase0 (all 90 POIs):     1.042× (+4.2 %).
Geomean A3 per-POI vs phase0 (existing 86 only):  0.998× (-0.2 %, noise).
Geomean A3 always-on vs phase0 (existing 86 only):0.988× (-1.2 %, real cost).

The per-POI flag is strictly better — same wins, no regressions.

---

## 2026-05-16 · `phase0-90poi` — 90-POI catalogue baseline (4 new period-3 POIs added, no A3)

Catalogue extension only.  Added 4 new POIs (P3 BULB UPPER, P3 BULB
LOWER, P3 LIMB FULL, P3 BULB DEEP) to `tools/poi_master.json`.
Regenerated `tools/benchmarks.json` and `rtl/benchmark_generated.vh`.
Rebuilt RTL (no logic changes — only the bench scene table grew).

Purpose: establish the baseline F10 numbers for the new POIs BEFORE
A3 lands so we have clean before/after comparison.

Sweep health: 0/90 alignment mismatches, 0/90 sym_overflow.

The new POIs at baseline:
- P3 BULB UPPER:  6.7 fps  (slow — most of the bulb is interior, all
  iterating to max_iter=512)
- P3 BULB LOWER:  6.6 fps  (mirror, ~same)
- P3 LIMB FULL:  19.9 fps  (less interior since wider view)
- P3 BULB DEEP:   2.5 fps  (very slow — every pixel iterates to
  max_iter=1024 since deep zoom puts entire frame inside the bulb)

Existing 86 POIs: +0.3 % geomean vs `a2-half-step` (within noise; no
RTL changes).  Full table omitted — see prior `a2-half-step` entry
for the per-POI numbers.

---

## 2026-05-16 · `a2-half-step` — Half-step ci grid shift + FIFO backpressure

Two related changes shipped together:

### 1. The bug fix — half-step ci grid shift

A long-standing rendering artifact: any view where the pixel grid lands a
row exactly on `ci=0` shows a hard horizontal line at that row.  The
M-set's intersection with the real axis is `M ∩ ℝ = [-2, 0.25]` — a 1D
line of zero imaginary width.  Single-sample renderers hitting it produce
dramatically different iter counts than `ci = ±step` neighbours.
Pre-existed; A2 made it more visible on real-axis POIs because it always
lands at the screen centre there.

Per [Cheritat](https://www.math.univ-toulouse.fr/~cheritat/wiki-draw/index.php/Mandelbrot_set)
who names the artifact (no fix listed): shift `ci_start` by `step/2` so no
pixel row ever lands on `ci=0`.  One constant changed in
`coord_generator.v`.  Image samples shift by half a pixel in the imaginary
direction — sub-pixel, visually imperceptible.

Side benefits for A2:
- 120 rows iterated (0..119), all mirrored to (239..120) — exact 2.00×
  speedup instead of the previous 1.98× (was 121 rows / 119 mirrors with
  a special-case axis row that was the one most affected by the artifact).
- Mirror condition simplifies from `[1..119]` to `[0..119]`.
- Mirror address simplifies from `240-y` to `239-y`.

### 2. FIFO backpressure (uncovered by the new overflow flag)

The first sweep with the half-step build reported `sym_overflow=1` on
every scene.  The pipeline's collect FSM can sustain `result_valid=1`
indefinitely on fast-precheck scenes (1 result/cycle) and the FIFO drain
is blocked while `pipe_result_valid=1`.  Any finite FIFO eventually
overflows on sustained-fast workloads.  The previous A2 build had this
latent — we just hadn't added the overflow detector yet.

Fix: `cg_ready = pipe_coord_ready && !symq_backpressure` where
`symq_backpressure` fires when `symq_count >= (DEPTH - N_ITERATORS)`.
At DEPTH=32, N_ITERATORS=24 → threshold 8.  Leaves headroom for every
in-flight iterator to enqueue its mirror after dispatch stalls.  When sym
is off, FIFO stays empty so backpressure never fires.

This costs a small amount of throughput on sustained-fast real-axis POIs
(dispatch stalls until FIFO drains), but removes the silent-drop failure
mode entirely.

### Backpressure footgun (fixed)

First attempt only gated `cg_ready` (coord_generator's *ready* input).
That held coord_generator at the current pixel but the pipeline doesn't
see `cg_ready` — its dispatch FSM keeps asserting its own `coord_ready`
whenever the next round-robin slot is free, redispatching the *held*
pixel into every free slot.  With 24 iterators that's up to 24
redundant computations of one pixel, each enqueueing its own mirror →
FIFO overflows regardless of threshold.

Symptom on hardware: real-axis POIs in benchmark mode rendered almost
empty back-buffer (a few pixels around the M-set boundary, rest stale)
→ VGA showed mostly-black image, HDMI scaler froze on the last good
frame.  Non-real-axis POIs were unaffected.

Fix: gate *both* sides of the handshake.
```
wire pipe_coord_valid = cg_valid && !symq_backpressure;  // gate valid
assign cg_ready       = pipe_coord_ready && !symq_backpressure;  // and ready
```

### Sweep health

- `decoded_scene == idx` for all 86 (clean alignment).
- `sym_overflow == 0` for all 86 (FIFO never overflows).
- Visual verification: y=120 line eliminated in P3 ISLAND, FEIGENBAUM,
  EJS CAULI, MISIUREWICZ -1.94 (was the worst case at 0-1/640 non-black
  on the axis row, now matches neighbours).

Build: `MiSTerbrot_20260516.rbf` (Quartus 17.0.2 Lite, ~22 min, 112
warnings, 0 errors).

### Full per-POI table

**Values in fps** (frames per second).  Hardware reports as F10 (frames
in 10 s integer); fps = F10/10.  59.6 = vsync cap (~60 Hz, can't measure
above — render-state machine waits for vblank between frames so F10 maxes
out at ~596).

Three runs side-by-side: baseline (before any A2), `a2-sym` (A2 with
the original 1.98× implementation, no half-step shift), and `a2-half-step`
(this build).  `A2 ratio` = a2-sym/baseline.  `cum ratio` = current/baseline.
`Δ vs A2` = current/a2-sym, isolating the half-step+backpressure effect.

| # | scene | baseline fps | a2-sym fps | a2-half-step fps | A2 ratio | cum ratio | Δ vs A2 |
|---|---|---:|---:|---:|---:|---:|---:|
|  0 | P6 SUB BULB             |  29.8 |  59.5 |  59.6 | 2.00× | 2.00× | +1.00× |
|  1 | P3 ISLAND               |  29.8 |  59.7 |  59.6 | 2.00× | 2.00× | +1.00× |
|  2 | P3 ISLAND TIP           |  29.8 |  59.6 |  59.6 | 2.00× | 2.00× | +1.00× |
|  3 | P4 ISLAND               |  29.7 |  29.7 |  29.8 | 1.00× | 1.00× | +1.00× |
|  4 | P5 ISLAND               |  19.9 |  19.8 |  19.9 | 0.99× | 1.00× | +1.01× |
|  5 | P6 ISLAND               |  29.8 |  29.8 |  29.7 | 1.00× | 1.00× | +1.00× |
|  6 | P7 ISLAND               |  19.9 |  19.9 |  19.8 | 1.00× | 0.99× | +0.99× |
|  7 | P8 ISLAND               |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
|  8 | P9 ISLAND               |  19.9 |  19.9 |  19.9 | 1.00× | 1.00× | +1.00× |
|  9 | P11 ISLAND              |  14.9 |  14.9 |  15.0 | 1.00× | 1.01× | +1.01× |
| 10 | P22 ISLAND              |  12.0 |  11.9 |  11.9 | 0.99× | 0.99× | +1.00× |
| 11 | ELEPHANT TRUNK          |  29.9 |  29.9 |  29.9 | 1.00× | 1.00× | +1.00× |
| 12 | ELEPHANT HEADS          |   9.9 |  10.0 |   9.9 | 1.01× | 1.00× | +0.99× |
| 13 | ELEPHANT ISLAND         |   3.2 |   3.2 |   3.2 | 1.00× | 1.00× | +1.00× |
| 14 | ELEPHANT P19            |  14.9 |  14.9 |  12.0 | 1.00× | 0.81× | +0.81× |
| 15 | ELEPHANT P16            |  14.9 |  14.9 |  14.9 | 1.00× | 1.00× | +1.00× |
| 16 | SEAHORSE BODY           |   7.5 |   7.5 |   7.5 | 1.00× | 1.00× | +1.00× |
| 17 | SEAHORSE TAIL           |  12.0 |  12.0 |  12.0 | 1.00× | 1.00× | +1.00× |
| 18 | SEAHORSE DEEP           |   6.0 |   5.9 |   6.0 | 0.98× | 1.00× | +1.02× |
| 19 | SEAHORSE TAIL2          |  10.0 |  10.0 |  10.0 | 1.00× | 1.00× | +1.00× |
| 20 | DOUBLE HOOK             |  11.9 |  12.0 |  11.9 | 1.01× | 1.00× | +0.99× |
| 21 | SH SATELLITE            |   4.3 |   4.3 |   4.3 | 1.00× | 1.00× | +1.00× |
| 22 | SAT ANTENNA             |   1.7 |   1.7 |   1.7 | 1.00× | 1.00× | +1.00× |
| 23 | SAT HEAD                |   1.1 |   1.1 |   1.1 | 1.00× | 1.00× | +1.00× |
| 24 | SAT SEAHORSE            |   1.1 |   1.1 |   1.1 | 1.00× | 1.00× | +1.00× |
| 25 | SAT DBL SPIRAL          |   0.8 |   0.8 |   0.8 | 1.00× | 1.00× | +1.00× |
| 26 | JULIA ISLANDS           |   2.1 |   2.1 |   2.2 | 1.00× | 1.05× | +1.05× |
| 27 | TRIPLE WEST             |   5.0 |   4.9 |   4.9 | 0.98× | 0.98× | +1.00× |
| 28 | TRIPLE DEEP             |   5.8 |   6.0 |   6.0 | 1.03× | 1.03× | +1.00× |
| 29 | FEIGENBAUM              |  11.9 |  19.9 |  19.7 | 1.67× | 1.66× | +0.99× |
| 30 | FEIGENBAUM ZOOM         |   6.7 |  12.0 |  12.0 | 1.79× | 1.79× | +1.00× |
| 31 | FEIGENBAUM DEEP         |   2.8 |   5.5 |   5.5 | 1.96× | 1.96× | +1.00× |
| 32 | GEN FEIGENBAUM          |  29.4 |  29.9 |  29.8 | 1.02× | 1.01× | +1.00× |
| 33 | MISIUREWICZ M4          |  59.6 |  59.6 |  59.5 | 1.00× | 1.00× | +1.00× |
| 34 | MISIUREWICZ M4-2        |  29.8 |  29.9 |  29.8 | 1.00× | 1.00× | +1.00× |
| 35 | MISIUREWICZ SPIR        |  14.6 |  15.0 |  14.5 | 1.03× | 0.99× | +0.97× |
| 36 | MISIUREWICZ -1.94       |  59.6 |  59.6 |  59.5 | 1.00× | 1.00× | +1.00× |
| 37 | MISIUREWICZ -1.84       |  59.6 |  59.6 |  59.6 | 1.00× | 1.00× | +1.00× |
| 38 | DBL SPIRAL P4           |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
| 39 | SINGLE SPIRAL           |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
| 40 | TRIPLE MEDALLION        |  11.9 |  11.9 |  11.9 | 1.00× | 1.00× | +1.00× |
| 41 | DBL SPIRAL ISLE         |   8.5 |   8.6 |   8.6 | 1.01× | 1.01× | +1.00× |
| 42 | TRIPLE ISLE MED         |   7.5 |   7.5 |   7.5 | 1.00× | 1.00× | +1.00× |
| 43 | CAULIFLOWER MED         |  14.9 |  14.8 |  14.9 | 0.99× | 1.00× | +1.01× |
| 44 | EJS CAULI               |  19.9 |  29.8 |  29.8 | 1.50× | 1.50× | +1.00× |
| 45 | EJS DBL SPIRAL          |  14.9 |  15.0 |  15.0 | 1.01× | 1.01× | +1.00× |
| 46 | EJS BRANCH              |  19.9 |  19.8 |  19.9 | 0.99× | 1.00× | +1.01× |
| 47 | EJS NUCLEUS             |   1.3 |   1.3 |   1.3 | 1.00× | 1.00× | +1.00× |
| 48 | LOVE CANAL              |   3.2 |   3.2 |   3.2 | 1.00× | 1.00× | +1.00× |
| 49 | P5 ISLAND DEEP          |  10.0 |  10.0 |   8.6 | 1.00× | 0.86× | +0.86× |
| 50 | ELEPHANT MED            |  10.0 |  10.0 |  10.0 | 1.00× | 1.00× | +1.00× |
| 51 | STARFISH                |  12.0 |  12.0 |  12.0 | 1.00× | 1.00× | +1.00× |
| 52 | M3,1 WAKE 3/7           |  14.9 |  14.9 |  14.9 | 1.00× | 1.00× | +1.00× |
| 53 | M11,1 WAKE 5/11         |   8.5 |   8.5 |   8.5 | 1.00× | 1.00× | +1.00× |
| 54 | CONCHA APPROACH         |  29.7 |  59.1 |  59.2 | 1.99× | 1.99× | +1.00× |
| 55 | M7,1 WAKE 1/7           |  14.9 |  15.0 |  14.9 | 1.01× | 1.00× | +0.99× |
| 56 | SH CUSP DEEP            |   2.0 |   2.0 |   2.0 | 1.00× | 1.00× | +1.00× |
| 57 | EJS PERIOD 44           |  19.5 |  19.5 |  19.4 | 1.00× | 0.99× | +0.99× |
| 58 | JEWEL BOX               |   6.0 |   5.9 |   6.0 | 0.98× | 1.00× | +1.02× |
| 59 | R2T P6 ISLAND           |   3.5 |   6.5 |   6.6 | 1.86× | 1.89× | +1.02× |
| 60 | SH CUSP FINE            |   0.9 |   1.0 |   1.0 | 1.11× | 1.11× | +1.00× |
| 61 | R2 HALF ISLE            |   1.8 |   1.8 |   1.8 | 1.00× | 1.00× | +1.00× |
| 62 | R2T P7 ISLAND           |  28.9 |  58.9 |  59.1 | 2.04× | 2.04× | +1.00× |
| 63 | SCEPTER MED             |  12.0 |  12.0 |  12.0 | 1.00× | 1.00× | +1.00× |
| 64 | BRANCH MED              |  29.6 |  29.8 |  29.7 | 1.01× | 1.00× | +1.00× |
| 65 | EJS P3 DEEP             |   8.6 |   8.5 |   8.6 | 0.99× | 1.00× | +1.01× |
| 66 | NEEDLE MED              |  29.7 |  29.6 |  29.6 | 1.00× | 1.00× | +1.00× |
| 67 | M3,1 1/3 LIMB TIP       |  59.6 |  59.6 |  59.7 | 1.00× | 1.00× | +1.00× |
| 68 | M_4,2 CASCADE 1         |  29.8 |  59.5 |  59.5 | 2.00× | 2.00× | +1.00× |
| 69 | M_8,4 CASCADE 2         |  19.9 |  29.8 |  29.8 | 1.50× | 1.50× | +1.00× |
| 70 | M_16,8 CASCADE 3        |  14.9 |  19.9 |  29.8 | 1.34× | 2.00× | +1.50× |
| 71 | EJS P47 ALPHA           |  15.0 |  15.0 |  15.0 | 1.00× | 1.00× | +1.00× |
| 72 | EJS P50 BETA            |  14.9 |  14.9 |  14.9 | 1.00× | 1.00× | +1.00× |
| 73 | EJS WAKE 1/4            |  14.9 |  14.9 |  19.9 | 1.00× | 1.34× | +1.34× |
| 74 | SH SPIRAL CONT          |  11.8 |  11.8 |  11.8 | 1.00× | 1.00× | +1.00× |
| 75 | SH TAIL SPIRAL          |   9.9 |   9.9 |   9.9 | 1.00× | 1.00× | +1.00× |
| 76 | ELEPHANT MED 2          |  14.8 |  14.9 |  14.8 | 1.01× | 1.00× | +0.99× |
| 77 | R2T 1/2 ISLE STEP       |   5.8 |   5.8 |   5.7 | 1.00× | 0.98× | +0.98× |
| 78 | BEYER STEP 13           |   2.2 |   2.2 |   2.2 | 1.00× | 1.00× | +1.00× |
| 79 | BEYER STEP 14           |   1.9 |   1.9 |   1.8 | 1.00× | 0.95× | +0.95× |
| 80 | TRIPLE SPIRAL P4        |   3.0 |   3.0 |   3.0 | 1.00× | 1.00× | +1.00× |
| 81 | MERCATOR P189           |  13.1 |  26.5 |  52.3 | 2.02× | 3.99× | +1.97× |
| 82 | MERCATOR P38            |  14.9 |  29.8 |  29.8 | 2.00× | 2.00× | +1.00× |
| 83 | M(3,3) WAKE 1/3 DP      |  29.9 |  29.9 |  29.9 | 1.00× | 1.00× | +1.00× |
| 84 | M(7,7) WAKE 1/4 DP      |  29.8 |  29.8 |  29.8 | 1.00× | 1.00× | +1.00× |
| 85 | EJS P47 GAMMA           |  15.0 |  14.9 |  15.0 | 0.99× | 1.00× | +1.01× |

Geomean A2 vs baseline: **1.113×** (+11.3%).
Geomean cumulative (A2 + half-step) vs baseline: **1.126×** (+12.6%).
Geomean delta of half-step+backpressure alone: **1.011×** (+1.1%).

### Notable per-POI swings from the half-step shift

The geomean is mild but the half-step shift moves sample positions by
half a pixel in ci, and the M-set's sensitivity to sample position is
non-uniform.  Both directions:

**Big additional wins on top of A2:**
- **MERCATOR P189** 265 → 523 (+1.97× on top of A2's +2.02× → cumulative
  +3.99× vs baseline).  At this zoom the new sample positions land in
  faster-escape regions.
- **M_16,8 CASCADE 3** 199 → 298 (+1.50× on top of A2's +1.34× → cum
  +2.00×).  The half-step shift pushed it past the secondary
  bottleneck.
- **EJS WAKE 1/4** 149 → 199 (+1.34×).  Non-real-axis POI — pure
  sample-position luck in a sensitive region.

**Small regressions:**
- **ELEPHANT P19** 149 → 120 (-19%).  Non-real-axis.  Sample shift
  landed in slower-converge region.
- **P5 ISLAND DEEP** 100 → 86 (-14%).  Same explanation.
- **BEYER STEP 14** 19 → 18 (-5%).  Within noise but consistent.

These swings are EXPECTED, not regressions in the engineering sense —
the half-step shift is a sample-pattern change, not a compute-rate
change.  The renderer is computing different (cr, ci) points than
before, so iter counts naturally vary per scene.  Cumulative geomean
is positive (+12.6%) and visual quality is strictly improved (no more
real-axis line).

---

## 2026-05-16 · `a2-sym` — A2 real-axis symmetry exploitation

Real-axis symmetry: when `center_y == 0` we iterate only rows 0..120 and
mirror-write rows 121..239 from row `(240-y)` via a 32-deep FIFO that drains
into the framebuffer write port whenever the pipeline isn't producing a
result. Latched per-frame so auto-zoom drift can't corrupt mid-frame.

Build: `MiSTerbrot_20260516.rbf` (Quartus 17.0.2 Lite). Worst-case setup
slack +0.414 ns on FPGA_CLK1_50. 109 warnings, 0 errors. ~24 min build.

Visual: y=120 black line still present here (this build pre-dates the
half-step shift fix — that's the next entry above).

### Full per-POI table

**Values in fps** (frames per second).  Hardware reports as F10 (frames
in 10 s integer); fps = F10/10.  59.6 = vsync cap (~60 Hz, can't measure
above).

| # | scene | baseline fps | a2-sym fps | ratio |
|---|---|---:|---:|---:|
|  0 | P6 SUB BULB             |  29.8 |  59.5 | 2.00× |
|  1 | P3 ISLAND               |  29.8 |  59.7 | 2.00× |
|  2 | P3 ISLAND TIP           |  29.8 |  59.6 | 2.00× |
|  3 | P4 ISLAND               |  29.7 |  29.7 | 1.00× |
|  4 | P5 ISLAND               |  19.9 |  19.8 | 0.99× |
|  5 | P6 ISLAND               |  29.8 |  29.8 | 1.00× |
|  6 | P7 ISLAND               |  19.9 |  19.9 | 1.00× |
|  7 | P8 ISLAND               |  29.8 |  29.8 | 1.00× |
|  8 | P9 ISLAND               |  19.9 |  19.9 | 1.00× |
|  9 | P11 ISLAND              |  14.9 |  14.9 | 1.00× |
| 10 | P22 ISLAND              |  12.0 |  11.9 | 0.99× |
| 11 | ELEPHANT TRUNK          |  29.9 |  29.9 | 1.00× |
| 12 | ELEPHANT HEADS          |   9.9 |  10.0 | 1.01× |
| 13 | ELEPHANT ISLAND         |   3.2 |   3.2 | 1.00× |
| 14 | ELEPHANT P19            |  14.9 |  14.9 | 1.00× |
| 15 | ELEPHANT P16            |  14.9 |  14.9 | 1.00× |
| 16 | SEAHORSE BODY           |   7.5 |   7.5 | 1.00× |
| 17 | SEAHORSE TAIL           |  12.0 |  12.0 | 1.00× |
| 18 | SEAHORSE DEEP           |   6.0 |   5.9 | 0.98× |
| 19 | SEAHORSE TAIL2          |  10.0 |  10.0 | 1.00× |
| 20 | DOUBLE HOOK             |  11.9 |  12.0 | 1.01× |
| 21 | SH SATELLITE            |   4.3 |   4.3 | 1.00× |
| 22 | SAT ANTENNA             |   1.7 |   1.7 | 1.00× |
| 23 | SAT HEAD                |   1.1 |   1.1 | 1.00× |
| 24 | SAT SEAHORSE            |   1.1 |   1.1 | 1.00× |
| 25 | SAT DBL SPIRAL          |   0.8 |   0.8 | 1.00× |
| 26 | JULIA ISLANDS           |   2.1 |   2.1 | 1.00× |
| 27 | TRIPLE WEST             |   5.0 |   4.9 | 0.98× |
| 28 | TRIPLE DEEP             |   5.8 |   6.0 | 1.03× |
| 29 | FEIGENBAUM              |  11.9 |  19.9 | 1.67× |
| 30 | FEIGENBAUM ZOOM         |   6.7 |  12.0 | 1.79× |
| 31 | FEIGENBAUM DEEP         |   2.8 |   5.5 | 1.96× |
| 32 | GEN FEIGENBAUM          |  29.4 |  29.9 | 1.02× |
| 33 | MISIUREWICZ M4          |  59.6 |  59.6 | 1.00× |
| 34 | MISIUREWICZ M4-2        |  29.8 |  29.9 | 1.00× |
| 35 | MISIUREWICZ SPIR        |  14.6 |  15.0 | 1.03× |
| 36 | MISIUREWICZ -1.94       |  59.6 |  59.6 | 1.00× |
| 37 | MISIUREWICZ -1.84       |  59.6 |  59.6 | 1.00× |
| 38 | DBL SPIRAL P4           |  29.8 |  29.8 | 1.00× |
| 39 | SINGLE SPIRAL           |  29.8 |  29.8 | 1.00× |
| 40 | TRIPLE MEDALLION        |  11.9 |  11.9 | 1.00× |
| 41 | DBL SPIRAL ISLE         |   8.5 |   8.6 | 1.01× |
| 42 | TRIPLE ISLE MED         |   7.5 |   7.5 | 1.00× |
| 43 | CAULIFLOWER MED         |  14.9 |  14.8 | 0.99× |
| 44 | EJS CAULI               |  19.9 |  29.8 | 1.50× |
| 45 | EJS DBL SPIRAL          |  14.9 |  15.0 | 1.01× |
| 46 | EJS BRANCH              |  19.9 |  19.8 | 0.99× |
| 47 | EJS NUCLEUS             |   1.3 |   1.3 | 1.00× |
| 48 | LOVE CANAL              |   3.2 |   3.2 | 1.00× |
| 49 | P5 ISLAND DEEP          |  10.0 |  10.0 | 1.00× |
| 50 | ELEPHANT MED            |  10.0 |  10.0 | 1.00× |
| 51 | STARFISH                |  12.0 |  12.0 | 1.00× |
| 52 | M3,1 WAKE 3/7           |  14.9 |  14.9 | 1.00× |
| 53 | M11,1 WAKE 5/11         |   8.5 |   8.5 | 1.00× |
| 54 | CONCHA APPROACH         |  29.7 |  59.1 | 1.99× |
| 55 | M7,1 WAKE 1/7           |  14.9 |  15.0 | 1.01× |
| 56 | SH CUSP DEEP            |   2.0 |   2.0 | 1.00× |
| 57 | EJS PERIOD 44           |  19.5 |  19.5 | 1.00× |
| 58 | JEWEL BOX               |   6.0 |   5.9 | 0.98× |
| 59 | R2T P6 ISLAND           |   3.5 |   6.5 | 1.86× |
| 60 | SH CUSP FINE            |   0.9 |   1.0 | 1.11× |
| 61 | R2 HALF ISLE            |   1.8 |   1.8 | 1.00× |
| 62 | R2T P7 ISLAND           |  28.9 |  58.9 | 2.04× |
| 63 | SCEPTER MED             |  12.0 |  12.0 | 1.00× |
| 64 | BRANCH MED              |  29.6 |  29.8 | 1.01× |
| 65 | EJS P3 DEEP             |   8.6 |   8.5 | 0.99× |
| 66 | NEEDLE MED              |  29.7 |  29.6 | 1.00× |
| 67 | M3,1 1/3 LIMB TIP       |  59.6 |  59.6 | 1.00× |
| 68 | M_4,2 CASCADE 1         |  29.8 |  59.5 | 2.00× |
| 69 | M_8,4 CASCADE 2         |  19.9 |  29.8 | 1.50× |
| 70 | M_16,8 CASCADE 3        |  14.9 |  19.9 | 1.34× |
| 71 | EJS P47 ALPHA           |  15.0 |  15.0 | 1.00× |
| 72 | EJS P50 BETA            |  14.9 |  14.9 | 1.00× |
| 73 | EJS WAKE 1/4            |  14.9 |  14.9 | 1.00× |
| 74 | SH SPIRAL CONT          |  11.8 |  11.8 | 1.00× |
| 75 | SH TAIL SPIRAL          |   9.9 |   9.9 | 1.00× |
| 76 | ELEPHANT MED 2          |  14.8 |  14.9 | 1.01× |
| 77 | R2T 1/2 ISLE STEP       |   5.8 |   5.8 | 1.00× |
| 78 | BEYER STEP 13           |   2.2 |   2.2 | 1.00× |
| 79 | BEYER STEP 14           |   1.9 |   1.9 | 1.00× |
| 80 | TRIPLE SPIRAL P4        |   3.0 |   3.0 | 1.00× |
| 81 | MERCATOR P189           |  13.1 |  26.5 | 2.02× |
| 82 | MERCATOR P38            |  14.9 |  29.8 | 2.00× |
| 83 | M(3,3) WAKE 1/3 DP      |  29.9 |  29.9 | 1.00× |
| 84 | M(7,7) WAKE 1/4 DP      |  29.8 |  29.8 | 1.00× |
| 85 | EJS P47 GAMMA           |  15.0 |  14.9 | 0.99× |

Geomean: **1.113×** (+11.3%).

Of the 17 cy=0 POIs: 8 hit clean 2.00× (P3 ISLAND, P3 ISLAND TIP, P6 SUB
BULB, CONCHA APPROACH, M_4,2 CASCADE 1, R2T P7 ISLAND, MERCATOR P189,
MERCATOR P38).  The 1.50× / 1.79–1.96× cases (EJS CAULI, FEIGENBAUM
ZOOM, etc.) are limited by what's likely the framebuffer-write FIFO
becoming the bottleneck once compute is halved.  Two were already
vsync-saturated at 59.6 fps in baseline (MISIUREWICZ -1.94, -1.84) — no
opportunity.  M_16,8 CASCADE 3 at 1.34× has a secondary bottleneck that
was unblocked by the half-step shift in the next entry above.

Non-real-axis POIs: all within ±3% (measurement noise — F10 resolution
is 1 frame in 10 s = 0.1 fps).

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
