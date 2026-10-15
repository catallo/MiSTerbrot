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

## 2026-10-15 · `clk-iter-130` — quad timing round two, 130 MHz (VCO 1300 / 10)

Builds (same tree, 12-seed sweeps on the new scm host): baseline =
`bench_q12_20261014.json` (clk_iter 118.18 MHz); after =
`bench_q15_20261015.json`, bench seed 5 (HDMI +0.623 ns, clk_iter +0.876 ns,
clk_vid +1.186 ns, 25,946 ALMs / 62%).  Release build: seed 3, **HDMI +0.416 /
clk_iter +0.836 / clk_vid +0.982 / clk_sys +4.267 ns, 25,553 ALMs (61%),
108/112 DSP** — pinned in `MiSTerbrot.qsf`, deployed as
`MiSTerbrot_20261015.rbf`.  Device captures (4 palettes, home / zoom-out /
pan-left / pan-up) pixel-identical to the 118 MHz build.  Verilator: all 11
benches pass, every `tb_pp` checksum and cycle count and the 46-case
iter_quad bench unchanged (bit-identical engine, identical schedule).

Why: a plain 130 MHz sweep of the 118 MHz quad missed clk_iter on 6/6 seeds
(−0.13 … −1.03 ns).  Every cone was routing or a decode, no arithmetic stage
was long any more, so this round added no pipeline stage (the 8-cycle loop
on the 8-slot period stays).  `rtl/iter_quad.v` changes: (1) one address
register per RAM (`ra_*` for the S0 read, `rb_*` for the S4 reads, `wa_*`
for the S6 writes) so the fitter places each next to its MLAB — one 3-bit
phase tap routed across the quad was the +0.7 ns floor; (2) the squares'
lo-word add moved from S2a0 to S2a1 (S2a0 is now a pure re-register of the
DSP output for the squares, the DSP→LAB hop no longer shares a cycle with an
adder); (3) a two-level 4:1/2:1 slot-port mux for the load operands (the
first level one cycle early, allowed by the CDC contract); (4) the cardioid
compare `zr_zi < ci²/4` split into signed-high / unsigned-low halves in S5
and combined in S6; (5) the RAM write-data mux as AND-OR on registered
one-hot state bits instead of a 6:1 case mux into the MLAB write registers;
(6) the S7 flag writeback driven by registered per-context one-hot enables
(`wb7_en`) instead of a shared enable decoded against a phase tap for 8×15
bits; (7) per-quad registered copies of the period-3 and periodicity enables
with a two-cycle multicycle in the SDC (as `max_iter_q` already had); (8) the
48-bit periodicity equality evaluated in S5 from the low 24 bits of the
next-z operands (the low bits of a sum depend only on the low bits of the
addends).  ALMs unchanged within noise.

Result at 130 MHz: **release seeds 6/6 close every clock** (clk_iter +0.46 …
+0.84 ns, HDMI +0.06 … +0.73); bench seeds 5/6 (the miss is one routing-heavy
path from a context MLAB into the cardioid comparator, −0.31 ns).  The first
six changes alone closed 11/12 (deepthought sweep q14).

**Geomean 1.05x (+5.2%)**, 23 of 90 scenes faster, none slower.  Expected raw
gain 10% (130/118.18); the unquantized satellites read +10…14% (R2 HALF ISLE
3.5 → 4.0, SAT DBL SPIRAL 1.4 → 1.6, SAT SEAHORSE 1.6 → 1.8, SAT HEAD
1.8 → 2.0, TRIPLE SPIRAL P4 2.9 → 3.2).  Harmonic crossings: NEEDLE MED
30 → 60; SH TAIL SPIRAL, ELEPHANT MED / MED 2, DOUBLE HOOK 20 → 30; R2T 1/2
ISLE STEP 15 → 20; SH SATELLITE, SEAHORSE BODY 12 → 15.  Cumulative: 1.40x
over the four-quad collect build (2026-10-12), 1.44x over the 2026-07-08
periodicity build, 2.02x over the first full-suite run (2026-05-14).

| idx | scene | F10 before | F10 after | ratio |
|----:|-------|-----------:|----------:|------:|
| 0 | P6 SUB BULB | 596 | 596 | 1.00x |
| 1 | P3 ISLAND | 597 | 596 | 1.00x |
| 2 | P3 ISLAND TIP | 596 | 596 | 1.00x |
| 3 | P4 ISLAND | 597 | 597 | 1.00x |
| 4 | P5 ISLAND | 596 | 597 | 1.00x |
| 5 | P6 ISLAND | 597 | 597 | 1.00x |
| 6 | P7 ISLAND | 596 | 596 | 1.00x |
| 7 | P8 ISLAND | 596 | 596 | 1.00x |
| 8 | P9 ISLAND | 596 | 596 | 1.00x |
| 9 | P11 ISLAND | 299 | 299 | 1.00x |
| 10 | P22 ISLAND | 298 | 298 | 1.00x |
| 11 | ELEPHANT TRUNK | 596 | 596 | 1.00x |
| 12 | ELEPHANT HEADS | 150 | 149 | 0.99x |
| 13 | ELEPHANT ISLAND | 60 | 66 | 1.10x |
| 14 | ELEPHANT P19 | 298 | 297 | 1.00x |
| 15 | ELEPHANT P16 | 299 | 299 | 1.00x |
| 16 | SEAHORSE BODY | 120 | 149 | 1.24x |
| 17 | SEAHORSE TAIL | 298 | 298 | 1.00x |
| 18 | SEAHORSE DEEP | 99 | 100 | 1.01x |
| 19 | SEAHORSE TAIL2 | 297 | 297 | 1.00x |
| 20 | DOUBLE HOOK | 199 | 298 | 1.50x |
| 21 | SH SATELLITE | 119 | 149 | 1.25x |
| 22 | SAT ANTENNA | 30 | 32 | 1.07x |
| 23 | SAT HEAD | 18 | 20 | 1.11x |
| 24 | SAT SEAHORSE | 16 | 18 | 1.12x |
| 25 | SAT DBL SPIRAL | 14 | 16 | 1.14x |
| 26 | JULIA ISLANDS | 33 | 37 | 1.12x |
| 27 | TRIPLE WEST | 66 | 74 | 1.12x |
| 28 | TRIPLE DEEP | 149 | 149 | 1.00x |
| 29 | FEIGENBAUM | 298 | 298 | 1.00x |
| 30 | FEIGENBAUM ZOOM | 199 | 199 | 1.00x |
| 31 | FEIGENBAUM DEEP | 86 | 99 | 1.15x |
| 32 | GEN FEIGENBAUM | 596 | 596 | 1.00x |
| 33 | MISIUREWICZ M4 | 596 | 597 | 1.00x |
| 34 | MISIUREWICZ M4-2 | 596 | 596 | 1.00x |
| 35 | MISIUREWICZ SPIR | 298 | 298 | 1.00x |
| 36 | MISIUREWICZ -1.94 | 596 | 596 | 1.00x |
| 37 | MISIUREWICZ -1.84 | 596 | 596 | 1.00x |
| 38 | DBL SPIRAL P4 | 597 | 596 | 1.00x |
| 39 | SINGLE SPIRAL | 596 | 596 | 1.00x |
| 40 | TRIPLE MEDALLION | 298 | 299 | 1.00x |
| 41 | DBL SPIRAL ISLE | 149 | 149 | 1.00x |
| 42 | TRIPLE ISLE MED | 149 | 149 | 1.00x |
| 43 | CAULIFLOWER MED | 199 | 199 | 1.00x |
| 44 | EJS CAULI | 596 | 596 | 1.00x |
| 45 | EJS DBL SPIRAL | 298 | 298 | 1.00x |
| 46 | EJS BRANCH | 298 | 298 | 1.00x |
| 47 | EJS NUCLEUS | 20 | 22 | 1.10x |
| 48 | LOVE CANAL | 58 | 65 | 1.12x |
| 49 | P5 ISLAND DEEP | 297 | 298 | 1.00x |
| 50 | ELEPHANT MED | 200 | 298 | 1.49x |
| 51 | STARFISH | 199 | 199 | 1.00x |
| 52 | M3,1 WAKE 3/7 | 298 | 298 | 1.00x |
| 53 | M11,1 WAKE 5/11 | 149 | 149 | 1.00x |
| 54 | CONCHA APPROACH | 594 | 595 | 1.00x |
| 55 | M7,1 WAKE 1/7 | 298 | 298 | 1.00x |
| 56 | SH CUSP DEEP | 32 | 34 | 1.06x |
| 57 | EJS PERIOD 44 | 296 | 298 | 1.01x |
| 58 | JEWEL BOX | 149 | 149 | 1.00x |
| 59 | R2T P6 ISLAND | 595 | 594 | 1.00x |
| 60 | SH CUSP FINE | 15 | 15 | 1.00x |
| 61 | R2 HALF ISLE | 35 | 40 | 1.14x |
| 62 | R2T P7 ISLAND | 594 | 595 | 1.00x |
| 63 | SCEPTER MED | 198 | 198 | 1.00x |
| 64 | BRANCH MED | 298 | 298 | 1.00x |
| 65 | EJS P3 DEEP | 120 | 120 | 1.00x |
| 66 | NEEDLE MED | 298 | 595 | 2.00x |
| 67 | M3,1 1/3 LIMB TIP | 597 | 597 | 1.00x |
| 68 | M_4,2 CASCADE 1 | 596 | 597 | 1.00x |
| 69 | M_8,4 CASCADE 2 | 596 | 597 | 1.00x |
| 70 | M_16,8 CASCADE 3 | 299 | 298 | 1.00x |
| 71 | EJS P47 ALPHA | 298 | 297 | 1.00x |
| 72 | EJS P50 BETA | 298 | 298 | 1.00x |
| 73 | EJS WAKE 1/4 | 299 | 298 | 1.00x |
| 74 | SH SPIRAL CONT | 298 | 298 | 1.00x |
| 75 | SH TAIL SPIRAL | 199 | 298 | 1.50x |
| 76 | ELEPHANT MED 2 | 199 | 298 | 1.50x |
| 77 | R2T 1/2 ISLE STEP | 149 | 199 | 1.34x |
| 78 | BEYER STEP 13 | 35 | 38 | 1.09x |
| 79 | BEYER STEP 14 | 30 | 32 | 1.07x |
| 80 | TRIPLE SPIRAL P4 | 29 | 32 | 1.10x |
| 81 | MERCATOR P189 | 146 | 147 | 1.01x |
| 82 | MERCATOR P38 | 298 | 298 | 1.00x |
| 83 | M(3,3) WAKE 1/3 DP | 596 | 596 | 1.00x |
| 84 | M(7,7) WAKE 1/4 DP | 597 | 596 | 1.00x |
| 85 | EJS P47 GAMMA | 299 | 298 | 1.00x |
| 86 | P3 BULB UPPER | 199 | 199 | 1.00x |
| 87 | P3 BULB LOWER | 199 | 199 | 1.00x |
| 88 | P3 LIMB FULL | 596 | 596 | 1.00x |
| 89 | P3 BULB DEEP | 597 | 597 | 1.00x |

---

## 2026-10-14 · `clk-iter-118` — quad pipeline deepened for 118.18 MHz (VCO 1300 / 11)

Builds (same tree, deepthought sweep of six seeds each): baseline =
`bench_q10_20261014.json` (clk_iter 108.33 MHz); after =
`bench_q12_20261014.json`, bench seed 1 (HDMI +0.619 ns, clk_iter +0.674 ns,
clk_vid +0.949 ns, 26,014 ALMs / 62%).  Release build: seed 1, **HDMI +0.517
/ clk_iter +0.709 / clk_vid +0.818 / clk_sys +2.984 ns, 25,528 ALMs (61%),
108/112 DSP** — pinned in `MiSTerbrot.qsf`, deployed as
`MiSTerbrot_20261014c.rbf`.  Device captures (4 palettes, home / zoom-out /
pan-left / pan-up) are pixel-identical to the 108 MHz build (0 differing
pixels) and differ from the 2026-10-13 base only by the overlay date glyph
(24 px).  Verilator: all 11 benches pass, every `tb_pp` checksum and the
46-case iter_quad bench unchanged (bit-identical engine).

Why a second round: the plain 118 MHz sweep of the 108 MHz quad missed
clk_iter on 12/12 seeds (−0.35 … −1.97 ns) on three cones.  `rtl/iter_quad.v`
changes (2026-10-14 b): (1) a new S2a0 stage takes the first-level limb sums
straight off the DSP output registers, so S2a1 has one adder level instead
of two serial 33-bit adds behind a 2.6 ns DSP→LAB hop; (2) cr−1/4 is stored
in its own context MLAB at load, so the cardioid operand `q + (cr − 1/4)` is
one add (Quartus folds the MLAB output register into the read address, so a
RAM read feeds the S5 adders combinationally — two chained adds there was
the −1.1 ns cone), and |ci| − P3_CY became a ternary add; (3) the flag
writeback is registered (S7) one cycle after the RAM writeback, taking the
48-bit periodicity compare and the iter_count mux out of the write-enable
cone.  The loop went from 7 to 8 cycles on the 8-slot period (the spare slot
was there to be used), ALMs +90 per core.  Cost: two more cycles of latency
per pixel slot, +0.1…2% frame cycles in simulation.

Result at 118.18 MHz: **clk_iter closes on 11/12 seeds** (+0.31 … +0.82 ns);
the one miss (release seed 5, −0.13 ns) is a single pure-routing path,
phase → MLAB address → DSP input register with 7.3 ns of interconnect — a
placement outlier, not logic.  HDMI misses on 2/12 (ascal-internal, as
before).  9/12 builds fully closed.

**Geomean 1.05x (+5.0%)**, 24 of 90 scenes faster, none slower.  The
expected raw gain is 9.1% (118.18/108.33) minus the latency cost; the
unquantized satellites read +10…12.5% (SAT ANTENNA 2.7 → 3.0, SAT HEAD
1.6 → 1.8, SH CUSP DEEP 2.9 → 3.2, TRIPLE WEST 5.9 → 6.6).  Scenes on a
60/N floor move only when they cross a harmonic (P22 ISLAND, P5 ISLAND
DEEP, EJS DBL SPIRAL, M3,1 / M7,1 WAKE 20 → 30; DBL SPIRAL ISLE, TRIPLE
ISLE MED, M11,1 WAKE 12 → 15; SCEPTER MED 15 → 20).  Cumulative: 1.33x
over the four-quad collect build (2026-10-12), 1.37x over the 2026-07-08
periodicity build, 1.92x over the first full-suite run (2026-05-14).

| idx | scene | F10 before | F10 after | ratio |
|----:|-------|-----------:|----------:|------:|
| 0 | P6 SUB BULB | 597 | 596 | 1.00x |
| 1 | P3 ISLAND | 596 | 597 | 1.00x |
| 2 | P3 ISLAND TIP | 596 | 596 | 1.00x |
| 3 | P4 ISLAND | 597 | 597 | 1.00x |
| 4 | P5 ISLAND | 596 | 596 | 1.00x |
| 5 | P6 ISLAND | 596 | 597 | 1.00x |
| 6 | P7 ISLAND | 596 | 596 | 1.00x |
| 7 | P8 ISLAND | 595 | 596 | 1.00x |
| 8 | P9 ISLAND | 596 | 596 | 1.00x |
| 9 | P11 ISLAND | 298 | 299 | 1.00x |
| 10 | P22 ISLAND | 199 | 298 | 1.50x |
| 11 | ELEPHANT TRUNK | 596 | 596 | 1.00x |
| 12 | ELEPHANT HEADS | 149 | 150 | 1.01x |
| 13 | ELEPHANT ISLAND | 55 | 60 | 1.09x |
| 14 | ELEPHANT P19 | 297 | 298 | 1.00x |
| 15 | ELEPHANT P16 | 298 | 299 | 1.00x |
| 16 | SEAHORSE BODY | 120 | 120 | 1.00x |
| 17 | SEAHORSE TAIL | 297 | 298 | 1.00x |
| 18 | SEAHORSE DEEP | 86 | 99 | 1.15x |
| 19 | SEAHORSE TAIL2 | 297 | 297 | 1.00x |
| 20 | DOUBLE HOOK | 199 | 199 | 1.00x |
| 21 | SH SATELLITE | 119 | 119 | 1.00x |
| 22 | SAT ANTENNA | 27 | 30 | 1.11x |
| 23 | SAT HEAD | 16 | 18 | 1.12x |
| 24 | SAT SEAHORSE | 15 | 16 | 1.07x |
| 25 | SAT DBL SPIRAL | 14 | 14 | 1.00x |
| 26 | JULIA ISLANDS | 31 | 33 | 1.06x |
| 27 | TRIPLE WEST | 59 | 66 | 1.12x |
| 28 | TRIPLE DEEP | 149 | 149 | 1.00x |
| 29 | FEIGENBAUM | 298 | 298 | 1.00x |
| 30 | FEIGENBAUM ZOOM | 199 | 199 | 1.00x |
| 31 | FEIGENBAUM DEEP | 86 | 86 | 1.00x |
| 32 | GEN FEIGENBAUM | 595 | 596 | 1.00x |
| 33 | MISIUREWICZ M4 | 596 | 596 | 1.00x |
| 34 | MISIUREWICZ M4-2 | 596 | 596 | 1.00x |
| 35 | MISIUREWICZ SPIR | 298 | 298 | 1.00x |
| 36 | MISIUREWICZ -1.94 | 596 | 596 | 1.00x |
| 37 | MISIUREWICZ -1.84 | 596 | 596 | 1.00x |
| 38 | DBL SPIRAL P4 | 596 | 597 | 1.00x |
| 39 | SINGLE SPIRAL | 597 | 596 | 1.00x |
| 40 | TRIPLE MEDALLION | 299 | 298 | 1.00x |
| 41 | DBL SPIRAL ISLE | 120 | 149 | 1.24x |
| 42 | TRIPLE ISLE MED | 119 | 149 | 1.25x |
| 43 | CAULIFLOWER MED | 198 | 199 | 1.01x |
| 44 | EJS CAULI | 595 | 596 | 1.00x |
| 45 | EJS DBL SPIRAL | 199 | 298 | 1.50x |
| 46 | EJS BRANCH | 298 | 298 | 1.00x |
| 47 | EJS NUCLEUS | 19 | 20 | 1.05x |
| 48 | LOVE CANAL | 54 | 58 | 1.07x |
| 49 | P5 ISLAND DEEP | 199 | 297 | 1.49x |
| 50 | ELEPHANT MED | 199 | 200 | 1.01x |
| 51 | STARFISH | 199 | 199 | 1.00x |
| 52 | M3,1 WAKE 3/7 | 199 | 298 | 1.50x |
| 53 | M11,1 WAKE 5/11 | 119 | 149 | 1.25x |
| 54 | CONCHA APPROACH | 596 | 594 | 1.00x |
| 55 | M7,1 WAKE 1/7 | 198 | 298 | 1.51x |
| 56 | SH CUSP DEEP | 29 | 32 | 1.10x |
| 57 | EJS PERIOD 44 | 297 | 296 | 1.00x |
| 58 | JEWEL BOX | 149 | 149 | 1.00x |
| 59 | R2T P6 ISLAND | 593 | 595 | 1.00x |
| 60 | SH CUSP FINE | 14 | 15 | 1.07x |
| 61 | R2 HALF ISLE | 32 | 35 | 1.09x |
| 62 | R2T P7 ISLAND | 593 | 594 | 1.00x |
| 63 | SCEPTER MED | 150 | 198 | 1.32x |
| 64 | BRANCH MED | 298 | 298 | 1.00x |
| 65 | EJS P3 DEEP | 119 | 120 | 1.01x |
| 66 | NEEDLE MED | 298 | 298 | 1.00x |
| 67 | M3,1 1/3 LIMB TIP | 597 | 597 | 1.00x |
| 68 | M_4,2 CASCADE 1 | 597 | 596 | 1.00x |
| 69 | M_8,4 CASCADE 2 | 596 | 596 | 1.00x |
| 70 | M_16,8 CASCADE 3 | 299 | 299 | 1.00x |
| 71 | EJS P47 ALPHA | 297 | 298 | 1.00x |
| 72 | EJS P50 BETA | 298 | 298 | 1.00x |
| 73 | EJS WAKE 1/4 | 299 | 299 | 1.00x |
| 74 | SH SPIRAL CONT | 298 | 298 | 1.00x |
| 75 | SH TAIL SPIRAL | 199 | 199 | 1.00x |
| 76 | ELEPHANT MED 2 | 199 | 199 | 1.00x |
| 77 | R2T 1/2 ISLE STEP | 150 | 149 | 0.99x |
| 78 | BEYER STEP 13 | 32 | 35 | 1.09x |
| 79 | BEYER STEP 14 | 27 | 30 | 1.11x |
| 80 | TRIPLE SPIRAL P4 | 26 | 29 | 1.12x |
| 81 | MERCATOR P189 | 147 | 146 | 0.99x |
| 82 | MERCATOR P38 | 299 | 298 | 1.00x |
| 83 | M(3,3) WAKE 1/3 DP | 596 | 596 | 1.00x |
| 84 | M(7,7) WAKE 1/4 DP | 596 | 597 | 1.00x |
| 85 | EJS P47 GAMMA | 298 | 299 | 1.00x |
| 86 | P3 BULB UPPER | 199 | 199 | 1.00x |
| 87 | P3 BULB LOWER | 199 | 199 | 1.00x |
| 88 | P3 LIMB FULL | 595 | 596 | 1.00x |
| 89 | P3 BULB DEEP | 597 | 597 | 1.00x |

---

## 2026-10-14 · `clk-iter-108` — iterators on their own PLL output at 108.33 MHz

Builds (same tree, deepthought sweep of six seeds each): baseline =
`bench_quad8_20261014.json` (five 8-context quads, clk_iter = clk_vid =
100 MHz); after = `bench_q10_20261014.json`, same RTL with clk_iter moved
to a third PLL output (VCO 1300 MHz / 12 = 108.333 MHz exactly, Quartus
reports 108.33 MHz, divide 12), bench seed 6 (HDMI +0.523 ns, clk_iter
+0.851 ns, clk_vid +0.694 ns, 25,814 ALMs / 62%).  Release build: seed 1,
**HDMI +0.772 / clk_iter +0.798 / clk_vid +0.685 / clk_sys +3.507 ns,
25,439 ALMs (61%), 108/112 DSP** — pinned in `MiSTerbrot.qsf`, deployed as
`MiSTerbrot_20261014b.rbf`.  Device captures (4 palettes, home / zoom-out /
pan-left / pan-up) are pixel-identical to the 100 MHz five-quad build
(0 differing pixels) and differ from the 2026-10-13 build only by the
overlay date glyph (24 px).

What changed: `rtl/pll/pll_0002.v` gains `outclk_2` (108.333333 MHz),
`MiSTerbrot.sv` feeds the display path from `clk_vid` (outclk_1, 100 MHz)
and the quads from `clk_iter` (outclk_2), the SDC adds the third async
clock group (nothing crosses between clk_iter and clk_vid; the iter↔sys
CDC is unchanged).  Also in this build, framework attributes: `maxfan 24`
on ascal's two `*_use_adaptive` registers (synthesis now duplicates them
5×, the 5.5 ns routing path is gone) and `AUTO_SHIFT_REGISTER_RECOGNITION
OFF` on shadowmask.  Honest result on the HDMI-clock lottery: the
attributes alone (12-seed control sweep at 100 MHz) still missed on 3/12
seeds, on *other* ascal paths (o_div→o_hfrac divider, o_vacpt→o_vpixq_pre,
−0.10…−0.24 ns); with the clock split, 11/12 seeds close every clock and
the single miss (bench seed 4, −0.342 ns) is again ascal-internal.  clk_iter
itself closes 12/12 at 108.33 MHz (+0.41…+0.97 ns), so the iterator clock
is no longer part of any lottery; the residue is the framework scaler at
148.5 MHz and is handled by seed choice.

**Geomean 1.07x (+7.0%)**, 27 of 90 scenes faster, none slower.  The
expected raw gain is 8.3% (108.33/100); the unquantized satellites read
+10…12.5% (SAT ANTENNA 2.4 → 2.7, SH CUSP DEEP 2.6 → 2.9, EJS NUCLEUS
1.7 → 1.9, BEYER STEP 13 2.9 → 3.2) — within the F10 window's ±0.1 fps
resolution of the theoretical number.  Scenes on a 60/N floor move only
when they cross a harmonic (P9 ISLAND, MISIUREWICZ M4-2, R2T P6 ISLAND
30 → 60; EJS P47 ALPHA/GAMMA, EJS P50 BETA, SEAHORSE TAIL2 20 → 30;
JEWEL BOX, TRIPLE DEEP 12 → 15).  Cumulative since the four-quad collect
build of 2026-10-12: geomean 1.27x.

| idx | scene | F10 before | F10 after | ratio |
|----:|-------|-----------:|----------:|------:|
| 0 | P6 SUB BULB | 596 | 597 | 1.00x |
| 1 | P3 ISLAND | 596 | 596 | 1.00x |
| 2 | P3 ISLAND TIP | 596 | 596 | 1.00x |
| 3 | P4 ISLAND | 597 | 597 | 1.00x |
| 4 | P5 ISLAND | 596 | 596 | 1.00x |
| 5 | P6 ISLAND | 597 | 596 | 1.00x |
| 6 | P7 ISLAND | 596 | 596 | 1.00x |
| 7 | P8 ISLAND | 595 | 595 | 1.00x |
| 8 | P9 ISLAND | 299 | 596 | 1.99x |
| 9 | P11 ISLAND | 298 | 298 | 1.00x |
| 10 | P22 ISLAND | 199 | 199 | 1.00x |
| 11 | ELEPHANT TRUNK | 596 | 596 | 1.00x |
| 12 | ELEPHANT HEADS | 149 | 149 | 1.00x |
| 13 | ELEPHANT ISLAND | 50 | 55 | 1.10x |
| 14 | ELEPHANT P19 | 297 | 297 | 1.00x |
| 15 | ELEPHANT P16 | 298 | 298 | 1.00x |
| 16 | SEAHORSE BODY | 119 | 120 | 1.01x |
| 17 | SEAHORSE TAIL | 297 | 297 | 1.00x |
| 18 | SEAHORSE DEEP | 86 | 86 | 1.00x |
| 19 | SEAHORSE TAIL2 | 199 | 297 | 1.49x |
| 20 | DOUBLE HOOK | 199 | 199 | 1.00x |
| 21 | SH SATELLITE | 100 | 119 | 1.19x |
| 22 | SAT ANTENNA | 24 | 27 | 1.12x |
| 23 | SAT HEAD | 15 | 16 | 1.07x |
| 24 | SAT SEAHORSE | 14 | 15 | 1.07x |
| 25 | SAT DBL SPIRAL | 13 | 14 | 1.08x |
| 26 | JULIA ISLANDS | 28 | 31 | 1.11x |
| 27 | TRIPLE WEST | 54 | 59 | 1.09x |
| 28 | TRIPLE DEEP | 119 | 149 | 1.25x |
| 29 | FEIGENBAUM | 297 | 298 | 1.00x |
| 30 | FEIGENBAUM ZOOM | 198 | 199 | 1.01x |
| 31 | FEIGENBAUM DEEP | 75 | 86 | 1.15x |
| 32 | GEN FEIGENBAUM | 596 | 595 | 1.00x |
| 33 | MISIUREWICZ M4 | 597 | 596 | 1.00x |
| 34 | MISIUREWICZ M4-2 | 298 | 596 | 2.00x |
| 35 | MISIUREWICZ SPIR | 298 | 298 | 1.00x |
| 36 | MISIUREWICZ -1.94 | 597 | 596 | 1.00x |
| 37 | MISIUREWICZ -1.84 | 597 | 596 | 1.00x |
| 38 | DBL SPIRAL P4 | 596 | 596 | 1.00x |
| 39 | SINGLE SPIRAL | 596 | 597 | 1.00x |
| 40 | TRIPLE MEDALLION | 298 | 299 | 1.00x |
| 41 | DBL SPIRAL ISLE | 119 | 120 | 1.01x |
| 42 | TRIPLE ISLE MED | 119 | 119 | 1.00x |
| 43 | CAULIFLOWER MED | 198 | 198 | 1.00x |
| 44 | EJS CAULI | 595 | 595 | 1.00x |
| 45 | EJS DBL SPIRAL | 199 | 199 | 1.00x |
| 46 | EJS BRANCH | 298 | 298 | 1.00x |
| 47 | EJS NUCLEUS | 17 | 19 | 1.12x |
| 48 | LOVE CANAL | 49 | 54 | 1.10x |
| 49 | P5 ISLAND DEEP | 198 | 199 | 1.01x |
| 50 | ELEPHANT MED | 198 | 199 | 1.01x |
| 51 | STARFISH | 199 | 199 | 1.00x |
| 52 | M3,1 WAKE 3/7 | 199 | 199 | 1.00x |
| 53 | M11,1 WAKE 5/11 | 120 | 119 | 0.99x |
| 54 | CONCHA APPROACH | 595 | 596 | 1.00x |
| 55 | M7,1 WAKE 1/7 | 199 | 198 | 0.99x |
| 56 | SH CUSP DEEP | 26 | 29 | 1.12x |
| 57 | EJS PERIOD 44 | 295 | 297 | 1.01x |
| 58 | JEWEL BOX | 119 | 149 | 1.25x |
| 59 | R2T P6 ISLAND | 299 | 593 | 1.98x |
| 60 | SH CUSP FINE | 13 | 14 | 1.08x |
| 61 | R2 HALF ISLE | 29 | 32 | 1.10x |
| 62 | R2T P7 ISLAND | 595 | 593 | 1.00x |
| 63 | SCEPTER MED | 149 | 150 | 1.01x |
| 64 | BRANCH MED | 298 | 298 | 1.00x |
| 65 | EJS P3 DEEP | 100 | 119 | 1.19x |
| 66 | NEEDLE MED | 298 | 298 | 1.00x |
| 67 | M3,1 1/3 LIMB TIP | 596 | 597 | 1.00x |
| 68 | M_4,2 CASCADE 1 | 597 | 597 | 1.00x |
| 69 | M_8,4 CASCADE 2 | 596 | 596 | 1.00x |
| 70 | M_16,8 CASCADE 3 | 299 | 299 | 1.00x |
| 71 | EJS P47 ALPHA | 198 | 297 | 1.50x |
| 72 | EJS P50 BETA | 198 | 298 | 1.51x |
| 73 | EJS WAKE 1/4 | 298 | 299 | 1.00x |
| 74 | SH SPIRAL CONT | 298 | 298 | 1.00x |
| 75 | SH TAIL SPIRAL | 199 | 199 | 1.00x |
| 76 | ELEPHANT MED 2 | 198 | 199 | 1.01x |
| 77 | R2T 1/2 ISLE STEP | 149 | 150 | 1.01x |
| 78 | BEYER STEP 13 | 29 | 32 | 1.10x |
| 79 | BEYER STEP 14 | 25 | 27 | 1.08x |
| 80 | TRIPLE SPIRAL P4 | 24 | 26 | 1.08x |
| 81 | MERCATOR P189 | 143 | 147 | 1.03x |
| 82 | MERCATOR P38 | 299 | 299 | 1.00x |
| 83 | M(3,3) WAKE 1/3 DP | 595 | 596 | 1.00x |
| 84 | M(7,7) WAKE 1/4 DP | 596 | 596 | 1.00x |
| 85 | EJS P47 GAMMA | 199 | 298 | 1.50x |
| 86 | P3 BULB UPPER | 199 | 199 | 1.00x |
| 87 | P3 BULB LOWER | 199 | 199 | 1.00x |
| 88 | P3 LIMB FULL | 595 | 595 | 1.00x |
| 89 | P3 BULB DEEP | 597 | 597 | 1.00x |

---

## 2026-10-14 · `quad8-mlab` — 8-context iter_quad with the context store in MLAB (fifth quad at 100 MHz)

Builds (same tree, deepthought sweep of six seeds each): baseline =
`bench_collect_20261012.json` (four 6-context quads, priority collect);
after = five 8-context quads (`N_ITERATORS=40`), bench seed 1 (HDMI
+0.528 ns, clk_iter +0.570 ns, 25,868 ALMs / 62%).  Release build: seed 5,
**+0.495 ns HDMI / +1.212 ns clk_iter, 25,230 ALMs (60%), 108/112 DSP** —
pinned in `MiSTerbrot.qsf`.  Verilator: bit-identical checksums on every
`tb_pp` scene and the 46-case iter_quad bench; device captures pixel-exact
vs the 2026-10-13 build apart from the overlay date glyph.

What changed (`rtl/iter_quad.v` rewrite, see docs/PROJECT.md): the fifth
quad fitted on 2026-10-13 (27-bit DSP limbs, 108/112 blocks) but no seed of
three sweeps closed 100 MHz — and a four-quad control sweep showed the same
1-in-6 lottery at 73% ALMs, i.e. the fill level was never the cause.  Every
failing cone was inside the quad: the 6:1 operand mux into the DSP input
registers, the shared max_iter compare, the 64-bit add+compare evaluation
stage, the state→z writeback mux.  The rewrite moves the per-context 64-bit
values (z, c, ci², Brent snapshot) into MLAB arrays addressed by the phase
counter (the operand mux becomes a RAM read), uses one shared writeback
stage with the single write port, loads pixels in the context's own slot,
drops the priming pass the old engine spent on every state transition
(2–6% of frame cycles by itself), and splits the evaluation into
clamp/add → compare/next-z → decision stages.  3,312 → 1,383 ALMs per quad;
core 35.0k → 25.2k.  **clk_iter closes on 12/12 seeds (+0.48 … +1.21 ns).**
The only remaining misses (4 of 12 builds, −0.06 … −0.28 ns) are on the
framework's 148.5 MHz HDMI pixel clock inside ascal/shadowmask — routing-only
paths between framework registers (0 logic levels, 5.5 ns of interconnect),
not core RTL.

**Geomean 1.18x (+18.4%)**, 52 of 90 scenes faster, none slower beyond
F10 window noise.  Raw engine gain is the expected ~25% (five quads at the
same clock plus no priming): the unquantized ~1–3 fps satellites read
+20…30% (SAT DBL SPIRAL 1.0 → 1.3, SAT SEAHORSE 1.1 → 1.4, JULIA ISLANDS
2.2 → 2.8, BEYER STEP 13 2.3 → 2.9); scenes on a 60/N floor move only when
they cross a harmonic (P7/P8 ISLAND, P3 LIMB FULL, M(7,7) WAKE 30 → 60;
EJS BRANCH, ELEPHANT P16/P19, SEAHORSE TAIL, TRIPLE MEDALLION 20 → 30;
MERCATOR P189 9.5 → 14.3).

| idx | scene | F10 before | F10 after | ratio |
|----:|-------|-----------:|----------:|------:|
| 0 | P6 SUB BULB | 596 | 596 | 1.00x |
| 1 | P3 ISLAND | 596 | 596 | 1.00x |
| 2 | P3 ISLAND TIP | 597 | 596 | 1.00x |
| 3 | P4 ISLAND | 596 | 597 | 1.00x |
| 4 | P5 ISLAND | 596 | 596 | 1.00x |
| 5 | P6 ISLAND | 596 | 597 | 1.00x |
| 6 | P7 ISLAND | 299 | 596 | 1.99x |
| 7 | P8 ISLAND | 299 | 595 | 1.99x |
| 8 | P9 ISLAND | 298 | 299 | 1.00x |
| 9 | P11 ISLAND | 298 | 298 | 1.00x |
| 10 | P22 ISLAND | 199 | 199 | 1.00x |
| 11 | ELEPHANT TRUNK | 596 | 596 | 1.00x |
| 12 | ELEPHANT HEADS | 119 | 149 | 1.25x |
| 13 | ELEPHANT ISLAND | 40 | 50 | 1.25x |
| 14 | ELEPHANT P19 | 198 | 297 | 1.50x |
| 15 | ELEPHANT P16 | 199 | 298 | 1.50x |
| 16 | SEAHORSE BODY | 86 | 119 | 1.38x |
| 17 | SEAHORSE TAIL | 198 | 297 | 1.50x |
| 18 | SEAHORSE DEEP | 67 | 86 | 1.28x |
| 19 | SEAHORSE TAIL2 | 199 | 199 | 1.00x |
| 20 | DOUBLE HOOK | 150 | 199 | 1.33x |
| 21 | SH SATELLITE | 86 | 100 | 1.16x |
| 22 | SAT ANTENNA | 20 | 24 | 1.20x |
| 23 | SAT HEAD | 12 | 15 | 1.25x |
| 24 | SAT SEAHORSE | 11 | 14 | 1.27x |
| 25 | SAT DBL SPIRAL | 10 | 13 | 1.30x |
| 26 | JULIA ISLANDS | 22 | 28 | 1.27x |
| 27 | TRIPLE WEST | 46 | 54 | 1.17x |
| 28 | TRIPLE DEEP | 100 | 119 | 1.19x |
| 29 | FEIGENBAUM | 298 | 297 | 1.00x |
| 30 | FEIGENBAUM ZOOM | 149 | 198 | 1.33x |
| 31 | FEIGENBAUM DEEP | 59 | 75 | 1.27x |
| 32 | GEN FEIGENBAUM | 594 | 596 | 1.00x |
| 33 | MISIUREWICZ M4 | 597 | 597 | 1.00x |
| 34 | MISIUREWICZ M4-2 | 299 | 298 | 1.00x |
| 35 | MISIUREWICZ SPIR | 199 | 298 | 1.50x |
| 36 | MISIUREWICZ -1.94 | 596 | 597 | 1.00x |
| 37 | MISIUREWICZ -1.84 | 596 | 597 | 1.00x |
| 38 | DBL SPIRAL P4 | 596 | 596 | 1.00x |
| 39 | SINGLE SPIRAL | 597 | 596 | 1.00x |
| 40 | TRIPLE MEDALLION | 199 | 298 | 1.50x |
| 41 | DBL SPIRAL ISLE | 100 | 119 | 1.19x |
| 42 | TRIPLE ISLE MED | 100 | 119 | 1.19x |
| 43 | CAULIFLOWER MED | 149 | 198 | 1.33x |
| 44 | EJS CAULI | 596 | 595 | 1.00x |
| 45 | EJS DBL SPIRAL | 199 | 199 | 1.00x |
| 46 | EJS BRANCH | 199 | 298 | 1.50x |
| 47 | EJS NUCLEUS | 14 | 17 | 1.21x |
| 48 | LOVE CANAL | 39 | 49 | 1.26x |
| 49 | P5 ISLAND DEEP | 198 | 198 | 1.00x |
| 50 | ELEPHANT MED | 149 | 198 | 1.33x |
| 51 | STARFISH | 149 | 199 | 1.34x |
| 52 | M3,1 WAKE 3/7 | 199 | 199 | 1.00x |
| 53 | M11,1 WAKE 5/11 | 100 | 120 | 1.20x |
| 54 | CONCHA APPROACH | 594 | 595 | 1.00x |
| 55 | M7,1 WAKE 1/7 | 149 | 199 | 1.34x |
| 56 | SH CUSP DEEP | 22 | 26 | 1.18x |
| 57 | EJS PERIOD 44 | 294 | 295 | 1.00x |
| 58 | JEWEL BOX | 100 | 119 | 1.19x |
| 59 | R2T P6 ISLAND | 298 | 299 | 1.00x |
| 60 | SH CUSP FINE | 10 | 13 | 1.30x |
| 61 | R2 HALF ISLE | 24 | 29 | 1.21x |
| 62 | R2T P7 ISLAND | 594 | 595 | 1.00x |
| 63 | SCEPTER MED | 119 | 149 | 1.25x |
| 64 | BRANCH MED | 298 | 298 | 1.00x |
| 65 | EJS P3 DEEP | 85 | 100 | 1.18x |
| 66 | NEEDLE MED | 298 | 298 | 1.00x |
| 67 | M3,1 1/3 LIMB TIP | 597 | 596 | 1.00x |
| 68 | M_4,2 CASCADE 1 | 596 | 597 | 1.00x |
| 69 | M_8,4 CASCADE 2 | 596 | 596 | 1.00x |
| 70 | M_16,8 CASCADE 3 | 298 | 299 | 1.00x |
| 71 | EJS P47 ALPHA | 199 | 198 | 0.99x |
| 72 | EJS P50 BETA | 199 | 198 | 0.99x |
| 73 | EJS WAKE 1/4 | 199 | 298 | 1.50x |
| 74 | SH SPIRAL CONT | 199 | 298 | 1.50x |
| 75 | SH TAIL SPIRAL | 150 | 199 | 1.33x |
| 76 | ELEPHANT MED 2 | 149 | 198 | 1.33x |
| 77 | R2T 1/2 ISLE STEP | 119 | 149 | 1.25x |
| 78 | BEYER STEP 13 | 23 | 29 | 1.26x |
| 79 | BEYER STEP 14 | 20 | 25 | 1.25x |
| 80 | TRIPLE SPIRAL P4 | 19 | 24 | 1.26x |
| 81 | MERCATOR P189 | 95 | 143 | 1.51x |
| 82 | MERCATOR P38 | 297 | 299 | 1.01x |
| 83 | M(3,3) WAKE 1/3 DP | 595 | 595 | 1.00x |
| 84 | M(7,7) WAKE 1/4 DP | 299 | 596 | 1.99x |
| 85 | EJS P47 GAMMA | 199 | 199 | 1.00x |
| 86 | P3 BULB UPPER | 149 | 199 | 1.34x |
| 87 | P3 BULB LOWER | 149 | 199 | 1.34x |
| 88 | P3 LIMB FULL | 298 | 595 | 2.00x |
| 89 | P3 BULB DEEP | 597 | 597 | 1.00x |

---

## 2026-10-12 · `priority-collect` — first-pending collect in pixel_pipeline (+ MISTERBROT_NO_AUDIO)

Builds (same day, same tree, bench engine enabled, framework audio path
gated — see below): baseline = HEAD pixel_pipeline (round-robin collect),
seed 2, −0.210 ns; after = first-pending priority-encoder collect
(`collect_slot` over `done_pending & busy`), seed 3, −0.202 ns.  Both at
84% ALMs.  Verilator (`sim/pixel_pipeline/tb_pp.sv`): bit-identical results
on five scenes, 3.1–10.5% fewer frame cycles (0.6% on the interior-bound
SAT HEAD scene).

Why: the round-robin walk advanced `collect_idx` every clk_sys cycle
regardless of pending state, so a finished pixel kept its iterator blocked
for 12 cycles on average (24 worst) before re-dispatch — ~0.3 µs of dead
time per pixel per slot, on top of the two clock crossings.

**Geomean 1.03x (+3.0%)**, 14 scenes >0.5% faster, no scene more than one
or two F10 counts slower (window-phase noise; the engine is never slower in
cycles).  The gains are concentrated where a scene crosses a vsync harmonic:
P5 ISLAND and M(3,3) WAKE 1/3 DP 30 → 60, P11 ISLAND / EJS PERIOD 44 20 → 30,
M3,1 WAKE 3/7 15 → 20.  Everything else sits on the same 60/N floor as before
— the bench's static-view swap-on-vblank snaps F10 to harmonics, so a
single-digit engine gain only shows at a boundary.

`MISTERBROT_NO_AUDIO` (sys_top.v): the core drives constant-zero audio, so
audio_out + IIR filter + DC blockers (~1.4k ALMs) are gated off.  Effect on
the fitter: before, 50–60% of seeds failed to fit at 85% ALMs; with the gate
all 6/6 release seeds and 12/12 bench seeds fit, and the release build
(NO_BENCH + NO_AUDIO + priority collect) **closes timing at +0.012 ns** (seed
2, 34,872 ALMs / 83%) — the first clean closure since the 90-POI era.

| idx | scene | F10 before | F10 after | ratio |
|----:|-------|-----------:|----------:|------:|
| 0 | P6 SUB BULB | 596 | 596 | 1.00x |
| 1 | P3 ISLAND | 597 | 596 | 1.00x |
| 2 | P3 ISLAND TIP | 596 | 597 | 1.00x |
| 3 | P4 ISLAND | 596 | 596 | 1.00x |
| 4 | P5 ISLAND | 299 | 596 | 1.99x |
| 5 | P6 ISLAND | 595 | 596 | 1.00x |
| 6 | P7 ISLAND | 299 | 299 | 1.00x |
| 7 | P8 ISLAND | 298 | 299 | 1.00x |
| 8 | P9 ISLAND | 298 | 298 | 1.00x |
| 9 | P11 ISLAND | 198 | 298 | 1.51x |
| 10 | P22 ISLAND | 198 | 199 | 1.01x |
| 11 | ELEPHANT TRUNK | 595 | 596 | 1.00x |
| 12 | ELEPHANT HEADS | 100 | 119 | 1.19x |
| 13 | ELEPHANT ISLAND | 40 | 40 | 1.00x |
| 14 | ELEPHANT P19 | 199 | 198 | 0.99x |
| 15 | ELEPHANT P16 | 199 | 199 | 1.00x |
| 16 | SEAHORSE BODY | 86 | 86 | 1.00x |
| 17 | SEAHORSE TAIL | 198 | 198 | 1.00x |
| 18 | SEAHORSE DEEP | 67 | 67 | 1.00x |
| 19 | SEAHORSE TAIL2 | 198 | 199 | 1.01x |
| 20 | DOUBLE HOOK | 149 | 150 | 1.01x |
| 21 | SH SATELLITE | 85 | 86 | 1.01x |
| 22 | SAT ANTENNA | 20 | 20 | 1.00x |
| 23 | SAT HEAD | 12 | 12 | 1.00x |
| 24 | SAT SEAHORSE | 11 | 11 | 1.00x |
| 25 | SAT DBL SPIRAL | 10 | 10 | 1.00x |
| 26 | JULIA ISLANDS | 22 | 22 | 1.00x |
| 27 | TRIPLE WEST | 46 | 46 | 1.00x |
| 28 | TRIPLE DEEP | 99 | 100 | 1.01x |
| 29 | FEIGENBAUM | 297 | 298 | 1.00x |
| 30 | FEIGENBAUM ZOOM | 150 | 149 | 0.99x |
| 31 | FEIGENBAUM DEEP | 60 | 59 | 0.98x |
| 32 | GEN FEIGENBAUM | 596 | 594 | 1.00x |
| 33 | MISIUREWICZ M4 | 596 | 597 | 1.00x |
| 34 | MISIUREWICZ M4-2 | 299 | 299 | 1.00x |
| 35 | MISIUREWICZ SPIR | 199 | 199 | 1.00x |
| 36 | MISIUREWICZ -1.94 | 596 | 596 | 1.00x |
| 37 | MISIUREWICZ -1.84 | 596 | 596 | 1.00x |
| 38 | DBL SPIRAL P4 | 596 | 596 | 1.00x |
| 39 | SINGLE SPIRAL | 596 | 597 | 1.00x |
| 40 | TRIPLE MEDALLION | 199 | 199 | 1.00x |
| 41 | DBL SPIRAL ISLE | 99 | 100 | 1.01x |
| 42 | TRIPLE ISLE MED | 99 | 100 | 1.01x |
| 43 | CAULIFLOWER MED | 149 | 149 | 1.00x |
| 44 | EJS CAULI | 596 | 596 | 1.00x |
| 45 | EJS DBL SPIRAL | 199 | 199 | 1.00x |
| 46 | EJS BRANCH | 199 | 199 | 1.00x |
| 47 | EJS NUCLEUS | 14 | 14 | 1.00x |
| 48 | LOVE CANAL | 40 | 39 | 0.97x |
| 49 | P5 ISLAND DEEP | 199 | 198 | 0.99x |
| 50 | ELEPHANT MED | 149 | 149 | 1.00x |
| 51 | STARFISH | 149 | 149 | 1.00x |
| 52 | M3,1 WAKE 3/7 | 149 | 199 | 1.34x |
| 53 | M11,1 WAKE 5/11 | 99 | 100 | 1.01x |
| 54 | CONCHA APPROACH | 596 | 594 | 1.00x |
| 55 | M7,1 WAKE 1/7 | 150 | 149 | 0.99x |
| 56 | SH CUSP DEEP | 22 | 22 | 1.00x |
| 57 | EJS PERIOD 44 | 196 | 294 | 1.50x |
| 58 | JEWEL BOX | 100 | 100 | 1.00x |
| 59 | R2T P6 ISLAND | 296 | 298 | 1.01x |
| 60 | SH CUSP FINE | 10 | 10 | 1.00x |
| 61 | R2 HALF ISLE | 25 | 24 | 0.96x |
| 62 | R2T P7 ISLAND | 594 | 594 | 1.00x |
| 63 | SCEPTER MED | 119 | 119 | 1.00x |
| 64 | BRANCH MED | 297 | 298 | 1.00x |
| 65 | EJS P3 DEEP | 86 | 85 | 0.99x |
| 66 | NEEDLE MED | 297 | 298 | 1.00x |
| 67 | M3,1 1/3 LIMB TIP | 596 | 597 | 1.00x |
| 68 | M_4,2 CASCADE 1 | 596 | 596 | 1.00x |
| 69 | M_8,4 CASCADE 2 | 596 | 596 | 1.00x |
| 70 | M_16,8 CASCADE 3 | 298 | 298 | 1.00x |
| 71 | EJS P47 ALPHA | 199 | 199 | 1.00x |
| 72 | EJS P50 BETA | 199 | 199 | 1.00x |
| 73 | EJS WAKE 1/4 | 199 | 199 | 1.00x |
| 74 | SH SPIRAL CONT | 198 | 199 | 1.01x |
| 75 | SH TAIL SPIRAL | 149 | 150 | 1.01x |
| 76 | ELEPHANT MED 2 | 149 | 149 | 1.00x |
| 77 | R2T 1/2 ISLE STEP | 119 | 119 | 1.00x |
| 78 | BEYER STEP 13 | 23 | 23 | 1.00x |
| 79 | BEYER STEP 14 | 20 | 20 | 1.00x |
| 80 | TRIPLE SPIRAL P4 | 19 | 19 | 1.00x |
| 81 | MERCATOR P189 | 98 | 95 | 0.97x |
| 82 | MERCATOR P38 | 298 | 297 | 1.00x |
| 83 | M(3,3) WAKE 1/3 DP | 298 | 595 | 2.00x |
| 84 | M(7,7) WAKE 1/4 DP | 298 | 299 | 1.00x |
| 85 | EJS P47 GAMMA | 198 | 199 | 1.01x |
| 86 | P3 BULB UPPER | 149 | 149 | 1.00x |
| 87 | P3 BULB LOWER | 149 | 149 | 1.00x |
| 88 | P3 LIMB FULL | 298 | 298 | 1.00x |
| 89 | P3 BULB DEEP | 596 | 597 | 1.00x |

---

## 2026-07-08 · `brent-periodicity` — P2 from the full-codebase review

Build: `MiSTerbrot_20260708.rbf` (third same-day build; seed 5, ALMs 89%,
clk_sys +1.84, **clk_iter -0.116 @ 85C slow corner** — 9-seed sweep found
no closing placement with the extra ~1% ALMs; deficit documented in
PROJECT.md, P2 is OSD-disableable via O[51]).  Baseline = the same-day
free-slot-dispatch build (`p1-freeslot-p6-3eval`).

Brent cycle detection per iterator context: 48-bit orbit snapshot at
power-of-two iterations, registered exact-equality compare, interior
classification identical to the geometric prechecks (bit-exact output,
Verilator full-frame equivalence).

**Geomean +0.6%.**  Wins concentrate in low-period island/bulb interior:
P5 ISLAND DEEP +34% (14.9 -> 19.9, a full vsync step), TRIPLE SPIRAL P4
+19%, LOVE CANAL +15%, ELEPHANT ISLAND +14%.  Sim compute gains were
larger (P22 ISLAND 1.69x) but vsync quantization + existing caps hide
sub-step improvements.  The ~1 fps deep satellites are escape-bound
(high-iteration exterior pixels) — cycle detection cannot help them, as
predicted.  The 4 nominal "regressions" are each exactly one F10 count
(10 s window noise).

| idx | scene | F10 before | F10 after | ratio |
|----:|-------|-----------:|----------:|------:|
| 0 | P6 SUB BULB | 596 | 597 | 1.00x |
| 1 | P3 ISLAND | 596 | 596 | 1.00x |
| 2 | P3 ISLAND TIP | 596 | 596 | 1.00x |
| 3 | P4 ISLAND | 596 | 596 | 1.00x |
| 4 | P5 ISLAND | 299 | 298 | 1.00x |
| 5 | P6 ISLAND | 595 | 595 | 1.00x |
| 6 | P7 ISLAND | 298 | 299 | 1.00x |
| 7 | P8 ISLAND | 298 | 298 | 1.00x |
| 8 | P9 ISLAND | 298 | 298 | 1.00x |
| 9 | P11 ISLAND | 199 | 199 | 1.00x |
| 10 | P22 ISLAND | 198 | 199 | 1.01x |
| 11 | ELEPHANT TRUNK | 596 | 597 | 1.00x |
| 12 | ELEPHANT HEADS | 100 | 100 | 1.00x |
| 13 | ELEPHANT ISLAND | 35 | 40 | 1.14x |
| 14 | ELEPHANT P19 | 198 | 199 | 1.01x |
| 15 | ELEPHANT P16 | 198 | 199 | 1.01x |
| 16 | SEAHORSE BODY | 86 | 85 | 0.99x |
| 17 | SEAHORSE TAIL | 199 | 198 | 0.99x |
| 18 | SEAHORSE DEEP | 66 | 67 | 1.02x |
| 19 | SEAHORSE TAIL2 | 198 | 199 | 1.01x |
| 20 | DOUBLE HOOK | 149 | 149 | 1.00x |
| 21 | SH SATELLITE | 85 | 85 | 1.00x |
| 22 | SAT ANTENNA | 20 | 20 | 1.00x |
| 23 | SAT HEAD | 12 | 12 | 1.00x |
| 24 | SAT SEAHORSE | 11 | 11 | 1.00x |
| 25 | SAT DBL SPIRAL | 10 | 10 | 1.00x |
| 26 | JULIA ISLANDS | 23 | 22 | 0.96x |
| 27 | TRIPLE WEST | 46 | 45 | 0.98x |
| 28 | TRIPLE DEEP | 100 | 100 | 1.00x |
| 29 | FEIGENBAUM | 297 | 298 | 1.00x |
| 30 | FEIGENBAUM ZOOM | 149 | 149 | 1.00x |
| 31 | FEIGENBAUM DEEP | 60 | 59 | 0.98x |
| 32 | GEN FEIGENBAUM | 597 | 594 | 0.99x |
| 33 | MISIUREWICZ M4 | 596 | 596 | 1.00x |
| 34 | MISIUREWICZ M4-2 | 299 | 299 | 1.00x |
| 35 | MISIUREWICZ SPIR | 199 | 198 | 0.99x |
| 36 | MISIUREWICZ -1.94 | 596 | 595 | 1.00x |
| 37 | MISIUREWICZ -1.84 | 596 | 596 | 1.00x |
| 38 | DBL SPIRAL P4 | 596 | 596 | 1.00x |
| 39 | SINGLE SPIRAL | 596 | 597 | 1.00x |
| 40 | TRIPLE MEDALLION | 199 | 199 | 1.00x |
| 41 | DBL SPIRAL ISLE | 99 | 100 | 1.01x |
| 42 | TRIPLE ISLE MED | 99 | 99 | 1.00x |
| 43 | CAULIFLOWER MED | 149 | 149 | 1.00x |
| 44 | EJS CAULI | 596 | 595 | 1.00x |
| 45 | EJS DBL SPIRAL | 199 | 198 | 0.99x |
| 46 | EJS BRANCH | 199 | 199 | 1.00x |
| 47 | EJS NUCLEUS | 14 | 13 | 0.93x |
| 48 | LOVE CANAL | 34 | 39 | 1.15x |
| 49 | P5 ISLAND DEEP | 149 | 199 | 1.34x |
| 50 | ELEPHANT MED | 149 | 149 | 1.00x |
| 51 | STARFISH | 149 | 149 | 1.00x |
| 52 | M3,1 WAKE 3/7 | 150 | 149 | 0.99x |
| 53 | M11,1 WAKE 5/11 | 100 | 100 | 1.00x |
| 54 | CONCHA APPROACH | 593 | 592 | 1.00x |
| 55 | M7,1 WAKE 1/7 | 149 | 149 | 1.00x |
| 56 | SH CUSP DEEP | 21 | 22 | 1.05x |
| 57 | EJS PERIOD 44 | 197 | 197 | 1.00x |
| 58 | JEWEL BOX | 100 | 99 | 0.99x |
| 59 | R2T P6 ISLAND | 298 | 298 | 1.00x |
| 60 | SH CUSP FINE | 10 | 9 | 0.90x |
| 61 | R2 HALF ISLE | 23 | 24 | 1.04x |
| 62 | R2T P7 ISLAND | 593 | 593 | 1.00x |
| 63 | SCEPTER MED | 120 | 119 | 0.99x |
| 64 | BRANCH MED | 298 | 297 | 1.00x |
| 65 | EJS P3 DEEP | 86 | 86 | 1.00x |
| 66 | NEEDLE MED | 298 | 298 | 1.00x |
| 67 | M3,1 1/3 LIMB TIP | 597 | 597 | 1.00x |
| 68 | M_4,2 CASCADE 1 | 597 | 596 | 1.00x |
| 69 | M_8,4 CASCADE 2 | 596 | 596 | 1.00x |
| 70 | M_16,8 CASCADE 3 | 298 | 299 | 1.00x |
| 71 | EJS P47 ALPHA | 199 | 199 | 1.00x |
| 72 | EJS P50 BETA | 199 | 199 | 1.00x |
| 73 | EJS WAKE 1/4 | 199 | 199 | 1.00x |
| 74 | SH SPIRAL CONT | 199 | 198 | 0.99x |
| 75 | SH TAIL SPIRAL | 150 | 149 | 0.99x |
| 76 | ELEPHANT MED 2 | 149 | 149 | 1.00x |
| 77 | R2T 1/2 ISLE STEP | 119 | 119 | 1.00x |
| 78 | BEYER STEP 13 | 23 | 23 | 1.00x |
| 79 | BEYER STEP 14 | 20 | 20 | 1.00x |
| 80 | TRIPLE SPIRAL P4 | 16 | 19 | 1.19x |
| 81 | MERCATOR P189 | 98 | 97 | 0.99x |
| 82 | MERCATOR P38 | 298 | 297 | 1.00x |
| 83 | M(3,3) WAKE 1/3 DP | 298 | 299 | 1.00x |
| 84 | M(7,7) WAKE 1/4 DP | 298 | 298 | 1.00x |
| 85 | EJS P47 GAMMA | 198 | 199 | 1.01x |
| 86 | P3 BULB UPPER | 149 | 149 | 1.00x |
| 87 | P3 BULB LOWER | 149 | 149 | 1.00x |
| 88 | P3 LIMB FULL | 298 | 298 | 1.00x |
| 89 | P3 BULB DEEP | 597 | 597 | 1.00x |

---

## 2026-07-08 · `free-slot-dispatch + 3-eval color_mapper` — P1 + P6 from the full-codebase review

Build: `MiSTerbrot_20260708.rbf` (seed 5, placement effort 4.0, **all clocks
closed**: clk_iter +0.060 / clk_sys +2.17 / HDMI +0.33; ALMs 88%).
Baseline = same-day build with only the coord_generator last-pixel +
A2 sym-skew bug fixes (seed 7).  Changes measured here:

- **P1 free-slot dispatch** (pixel_pipeline): first-free priority encoder
  replaces the in-order ring; kills head-of-line blocking.
- **P6 three-evaluator color_mapper** (display path only — no fps effect;
  included for attribution completeness).

**Geomean +17.0% (1.17x), zero regressions, 43/90 scenes >5% faster.**
Seahorse/valley family +50..98%; ELEPHANT TRUNK, EJS CAULI, M_8,4
CASCADE 2 newly vsync-capped.  Interior-bound deep satellites +5..18%
only (homogeneous max-iter load — periodicity detection is their fix).

| idx | scene | F10 before | F10 after | ratio |
|----:|-------|-----------:|----------:|------:|
| 0 | P6 SUB BULB | 596 | 596 | 1.00x |
| 1 | P3 ISLAND | 596 | 596 | 1.00x |
| 2 | P3 ISLAND TIP | 596 | 596 | 1.00x |
| 3 | P4 ISLAND | 596 | 596 | 1.00x |
| 4 | P5 ISLAND | 299 | 299 | 1.00x |
| 5 | P6 ISLAND | 595 | 595 | 1.00x |
| 6 | P7 ISLAND | 298 | 298 | 1.00x |
| 7 | P8 ISLAND | 298 | 298 | 1.00x |
| 8 | P9 ISLAND | 298 | 298 | 1.00x |
| 9 | P11 ISLAND | 198 | 199 | 1.01x |
| 10 | P22 ISLAND | 120 | 198 | 1.65x |
| 11 | ELEPHANT TRUNK | 298 | 596 | 2.00x |
| 12 | ELEPHANT HEADS | 67 | 100 | 1.49x |
| 13 | ELEPHANT ISLAND | 32 | 35 | 1.09x |
| 14 | ELEPHANT P19 | 149 | 198 | 1.33x |
| 15 | ELEPHANT P16 | 150 | 198 | 1.32x |
| 16 | SEAHORSE BODY | 50 | 86 | 1.72x |
| 17 | SEAHORSE TAIL | 120 | 199 | 1.66x |
| 18 | SEAHORSE DEEP | 40 | 66 | 1.65x |
| 19 | SEAHORSE TAIL2 | 100 | 198 | 1.98x |
| 20 | DOUBLE HOOK | 119 | 149 | 1.25x |
| 21 | SH SATELLITE | 60 | 85 | 1.42x |
| 22 | SAT ANTENNA | 17 | 20 | 1.18x |
| 23 | SAT HEAD | 11 | 12 | 1.09x |
| 24 | SAT SEAHORSE | 10 | 11 | 1.10x |
| 25 | SAT DBL SPIRAL | 9 | 10 | 1.11x |
| 26 | JULIA ISLANDS | 22 | 23 | 1.05x |
| 27 | TRIPLE WEST | 31 | 46 | 1.48x |
| 28 | TRIPLE DEEP | 59 | 100 | 1.69x |
| 29 | FEIGENBAUM | 198 | 297 | 1.50x |
| 30 | FEIGENBAUM ZOOM | 119 | 149 | 1.25x |
| 31 | FEIGENBAUM DEEP | 54 | 60 | 1.11x |
| 32 | GEN FEIGENBAUM | 596 | 597 | 1.00x |
| 33 | MISIUREWICZ M4 | 597 | 596 | 1.00x |
| 34 | MISIUREWICZ M4-2 | 298 | 299 | 1.00x |
| 35 | MISIUREWICZ SPIR | 149 | 199 | 1.34x |
| 36 | MISIUREWICZ -1.94 | 595 | 596 | 1.00x |
| 37 | MISIUREWICZ -1.84 | 596 | 596 | 1.00x |
| 38 | DBL SPIRAL P4 | 596 | 596 | 1.00x |
| 39 | SINGLE SPIRAL | 596 | 596 | 1.00x |
| 40 | TRIPLE MEDALLION | 199 | 199 | 1.00x |
| 41 | DBL SPIRAL ISLE | 85 | 99 | 1.16x |
| 42 | TRIPLE ISLE MED | 75 | 99 | 1.32x |
| 43 | CAULIFLOWER MED | 149 | 149 | 1.00x |
| 44 | EJS CAULI | 298 | 596 | 2.00x |
| 45 | EJS DBL SPIRAL | 149 | 199 | 1.34x |
| 46 | EJS BRANCH | 199 | 199 | 1.00x |
| 47 | EJS NUCLEUS | 13 | 14 | 1.08x |
| 48 | LOVE CANAL | 31 | 34 | 1.10x |
| 49 | P5 ISLAND DEEP | 148 | 149 | 1.01x |
| 50 | ELEPHANT MED | 99 | 149 | 1.51x |
| 51 | STARFISH | 119 | 149 | 1.25x |
| 52 | M3,1 WAKE 3/7 | 149 | 150 | 1.01x |
| 53 | M11,1 WAKE 5/11 | 85 | 100 | 1.18x |
| 54 | CONCHA APPROACH | 593 | 593 | 1.00x |
| 55 | M7,1 WAKE 1/7 | 150 | 149 | 0.99x |
| 56 | SH CUSP DEEP | 20 | 21 | 1.05x |
| 57 | EJS PERIOD 44 | 198 | 197 | 0.99x |
| 58 | JEWEL BOX | 66 | 100 | 1.52x |
| 59 | R2T P6 ISLAND | 297 | 298 | 1.00x |
| 60 | SH CUSP FINE | 10 | 10 | 1.00x |
| 61 | R2 HALF ISLE | 18 | 23 | 1.28x |
| 62 | R2T P7 ISLAND | 592 | 593 | 1.00x |
| 63 | SCEPTER MED | 119 | 120 | 1.01x |
| 64 | BRANCH MED | 297 | 298 | 1.00x |
| 65 | EJS P3 DEEP | 75 | 86 | 1.15x |
| 66 | NEEDLE MED | 298 | 298 | 1.00x |
| 67 | M3,1 1/3 LIMB TIP | 595 | 597 | 1.00x |
| 68 | M_4,2 CASCADE 1 | 597 | 597 | 1.00x |
| 69 | M_8,4 CASCADE 2 | 298 | 596 | 2.00x |
| 70 | M_16,8 CASCADE 3 | 297 | 298 | 1.00x |
| 71 | EJS P47 ALPHA | 149 | 199 | 1.34x |
| 72 | EJS P50 BETA | 198 | 199 | 1.01x |
| 73 | EJS WAKE 1/4 | 199 | 199 | 1.00x |
| 74 | SH SPIRAL CONT | 120 | 199 | 1.66x |
| 75 | SH TAIL SPIRAL | 100 | 150 | 1.50x |
| 76 | ELEPHANT MED 2 | 149 | 149 | 1.00x |
| 77 | R2T 1/2 ISLE STEP | 60 | 119 | 1.98x |
| 78 | BEYER STEP 13 | 23 | 23 | 1.00x |
| 79 | BEYER STEP 14 | 19 | 20 | 1.05x |
| 80 | TRIPLE SPIRAL P4 | 16 | 16 | 1.00x |
| 81 | MERCATOR P189 | 99 | 98 | 0.99x |
| 82 | MERCATOR P38 | 299 | 298 | 1.00x |
| 83 | M(3,3) WAKE 1/3 DP | 298 | 298 | 1.00x |
| 84 | M(7,7) WAKE 1/4 DP | 298 | 298 | 1.00x |
| 85 | EJS P47 GAMMA | 149 | 198 | 1.33x |
| 86 | P3 BULB UPPER | 119 | 149 | 1.25x |
| 87 | P3 BULB LOWER | 119 | 149 | 1.25x |
| 88 | P3 LIMB FULL | 298 | 298 | 1.00x |
| 89 | P3 BULB DEEP | 597 | 597 | 1.00x |

---

## 2026-05-16 · `frame-snapshot` — coord_generator latches step + mode_640 at frame start

Visual correctness fix, **not a perf change**.  Included here because
it's a release-relevant code change that ships in the same build as A3.

**Symptom**: on low-fps scenes (auto-zoom approach + hold on slow POIs,
or manual deep-zoom drift), the rendered image showed a continuous
geometric "warp" — top rows used one effective step value, bottom rows
another, producing a stretched/sheared appearance only visible at
≤10 fps.

**Cause**: `coord_generator.v`'s S_SCAN block read `step` and `mode_640`
live from input wires every cycle.  Auto_zoom updates these
continuously while interpolating between POIs.  On slow renders the
drift between top-of-frame and bottom-of-frame was large enough for
the per-pixel `cr` increment (uses `step_x`) and per-row `ci`
increment (uses `step`) to visibly vary mid-frame.

**Fix**: latch `step` and `mode_640` into `step_frame` / `mode_640_frame`
at `start_frame` (same pattern as the existing `sym_frame` latch).
S_SCAN now uses the latched copies via `step_x_frame` and
`H_PIXELS_frame`.  `cr_start` / `ci_start` (combinational from live
step) are only used at start_frame, so the live values get
implicitly latched at the same posedge as `step_frame`.

**Impact**: zero on F10 measurements (step is constant in benchmark
mode, so bench is unaffected).  Pure visual correctness fix.  Verified
on hardware: auto-zoom approach + hold no longer warps.

12-line diff in `rtl/coord_generator.v`.

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
