# Track B — 640×480 via DDR3 framebuffer (Design)

Status: PLANNED (2026-07-09).  Follows completion of 320×480i (see
480I_DESIGN.md).  Supersedes the SDRAM-based Track B section in
ROADMAP.md.

Goal: 640×480 rendering — 4× the pixels of 320×240 — which no longer
fits BRAM (two 307,200-entry banks ≈ 600 M10K > 553 available).  The
framebuffer moves to DDR3; everything else about the core's display
philosophy stays as it is today.

## Memory decision (recap)

**DDR3 via the f2sdram bridge, not the SDRAM addon** (decided
2026-07-09, user confirmed despite owning a 128 MB SDRAM module):

1. Zero new infrastructure: the emu `DDRAM_*` port (64-bit Avalon
   burst master) is already wired in sys_top to an f2sdram port and
   currently tied off in MiSTerbrot.sv.  No SDRAM controller, no
   external-pin IO timing.
2. Our bandwidth need (~20-40 MB/s reads + <100 MB/s peak writes) is
   trivial against f2sdram's >1 GB/s; the shared-bus latency variance
   is absorbed by a full-line prefetch margin (64 µs budget for ~3 µs
   of data).
3. DDR3 is ARM-shared memory — exactly the Track C perturbation
   scenario (ARM computes reference orbits, core reads them directly).
4. No "SDRAM module required" install-base restriction.

## Architecture choice

Three candidates were considered:

**A (CHOSEN): DDR3 iteration-data framebuffer + core-side scanout.**
The BRAM banks are replaced (for the new modes) by DDR3 buffers holding
the same 9-bit `{escaped, iter[7:0]}` words; a line-prefetch engine
feeds a BRAM line buffer; scanout, color_mapper, text overlay and sync
generation are untouched.  Preserves everything that defines the core
today: live palette cycling/crossfade WITHOUT re-render (color mapping
happens at scanout), overlay composited after the framebuffer read,
native analog timing, auto_zoom's framebuffer sampling, benchmark HUD.

**B (rejected): framework framebuffer (`MISTER_FB`), RGB format.**
The core writes RGB pixels to DDR3 and ascal scans them out directly.
Rejected: color cycling would force a full-frame rewrite every frame
(color is baked at render time), the text overlay would have to be
drawn into the framebuffer with save/restore under motion, and output
exists only through the scaler — native 15 kHz dies.

**C (rejected): framework framebuffer, 8-bit indexed + `FB_PAL`.**
Elegant on paper (write `cidx` once; palette animation = rewriting ~91
palette entries per vblank, ascal applies them), but shares B's fatal
overlay and native-output losses, and auto_zoom would still need its
own DDR3 read path.  Recorded here because the palette trick is worth
remembering if a scaler-only mode is ever wanted.

## Memory map and word layout

- 16-bit framebuffer words: `{7'b0, escaped, iter[7:0]}`.  The 7 pad
  bits are free in DDR3 and buy clean byte-lane addressing.
- Power-of-2 row stride: 2048 bytes (1024 words).  Address = shift
  only, burst-aligned rows.  480 rows × 2048 B ≈ 0.94 MB per bank.
- Two banks (same whole-frame swap-on-vblank discipline as BRAM) at
  the conventional core DDR3 base `0x3000_0000`:
  bank A `0x3000_0000`, bank B `0x3010_0000`.  Total < 2 MB.
- `DDRAM_ADDR` addresses 64-bit words (29 bits): base word address
  `0x0600_0000`, row stride 256 words, 4 pixels per word.

## Read path — line prefetch

- Double line buffer in BRAM: 2 × 640 × 16 bit ≈ 2 M10K (ping-pong).
- While row N scans out of one buffer, row N+1 (logical row
  `2*(N+1)+field` in 480i) bursts into the other: 160 beats of 64-bit,
  e.g. 4 bursts of 40.  Data time ≈ 3 µs at 100 MHz; budget = one full
  line period (64 µs at 15.6 kHz; still 32 µs for future 480p).  The
  variance of the shared f2sdram bus disappears into that margin.
- The display path NEVER reads DDR3 directly — only the line buffer.
  An underrun (bus stalled >1 line, should be impossible) shows the
  previous line rather than garbage; a sticky diagnostic flag is
  exposed for bring-up.
- auto_zoom's framebuffer sampling snoops the line-buffer read data at
  scanout time (same values the display sees), as it does today on the
  BRAM read port.

## Write path — the one real problem

Free-slot dispatch means results complete OUT OF SCAN ORDER, and A2
mirror writes target row `479−y` — writes are scattered 16-bit stores,
which is the worst pattern for a burst-oriented bus.

- Stage-1 design: write FIFO (≈512 deep, MLAB/M10K) capturing
  `{addr, 9-bit data}` at up to 1/clk_sys, drained as single-beat
  64-bit writes with 2-of-8 byte enables.  Posted writes; drain rate
  is waitrequest-bound.
- Budget check: sustained pixel rate is iterator-bound (≤ ~5 M px/s
  even on vsync-capped easy scenes, ×2 with mirror drain).  Even a
  pessimistic 15 M single-beat writes/s through f2sdram covers it.
  Peak bursts (coord ladder start, low-iter runs at 50 M results/s)
  are absorbed by the FIFO; if it fills, dispatch stalls (existing
  `coord_ready` backpressure) — correctness never depends on drain
  rate.
- Optional coalescer (stage 2, only if measurement demands it):
  combine FIFO entries hitting the same 64-bit word (4 px).  Dispatch
  is scan-ordered and slot skew is bounded in practice, so neighbors
  often coalesce; mirror writes won't (far row) and don't need to.
- Early hardware probe: before integration, a throwaway test harness
  measures real scattered-write and burst-read throughput through
  ram1 under ascal load.  Numbers, not folklore, pick the coalescer.

## Clocking / CDC

`DDRAM_CLK = clk_sys` (50 MHz).  The entire framebuffer path already
lives in clk_sys (iter results are CDC'd by the collect FSM today), so
the DDR3 adapter adds NO new clock domain and no new CDC.  f2sdram
handles the crossing to the HPS side internally.

## Video timing and OSD

- **640×480i needs no new video timing**: the 262/263 half-line
  scheme from 320×480i is width-agnostic; 640-wide just means ce_pix
  12.5 MHz (as in 640×240 today).  `mode_640` and `mode_480` are
  already independent muxes in coord_generator — 640×480 sets both.
- OSD: `O[55:54]` value 3 is free → Resolution menu becomes
  320x240 / 640x240 / 320x480i / **640x480i**.  The J key cycles all
  four.  All 480i bring-up rules apply unchanged: boot grace (~60
  vblanks progressive), `new_vmode` toggle on change, direct dvid_*
  path when interlaced, Deinterlace O[58:57] applies as-is.
- **480p (31 kHz) is a separate later stage**: 525 progressive lines,
  ~25 MHz pixel clock, breaks strict 15 kHz support → own timing mode,
  own OSD value (widen the field then), PLL output already provides
  50 MHz/4... to be scoped when we get there.  Nothing in the DDR3
  design binds to interlace.

## What stays untouched

- color_mapper (palette/cycling/crossfade at scanout), text overlay,
  input/auto_zoom/randomizer, iter_quad and the whole 100 MHz domain.
- **The BRAM framebuffer stays** and keeps serving 320x240 / 640x240 /
  320x480i bit-identically; DDR3 serves only 640×480 modes.  M10K
  budget allows both (300 banks + ~4 line/FIFO blocks).  Rationale:
  zero regression risk for verified modes, benchmark determinism
  (benchmarks force 240p BRAM as today), and a working fallback if
  DDR3 misbehaves in the field.  Unification (dropping BRAM banks,
  freeing 300 M10K) is a possible LATER cleanup once the DDR3 path
  has soaked.

## Performance expectation

Rendering is iterator-bound; DDR3 adds no iteration cost.  640×480 =
4× the pixels of 320×240 → fps ≈ ¼ per scene (A2-symmetric POIs keep
their halving).  Scenes that vsync-cap at 60 today land around 15-30;
deep islands proportionally lower.  P1/P2/A2 wins carry over.  This is
the expected trade and the reason 640×480 is an option, not the
default.

## Verification plan

1. Behavioral Avalon DDR3 model with randomized waitrequest/latency
   (seeded), TB for the adapter alone: no line underrun at worst-case
   latency, no FIFO overflow with backpressure, address/byte-enable
   correctness.
2. Bit-exactness: render identical frames through BRAM path and DDR3
   adapter model; framebuffer contents must match exactly.
3. Pair-TB fractal_top old-vs-new in all existing modes (bit-identical
   sync + pixel streams — the 480i methodology).
4. Hardware: bandwidth probe first (see write path); then A2 mirror
   correlation on silicon, 240p walkthrough 90/90 regression, 640×480i
   liveness + geometry captures.  Walkthrough stays 240p until the
   Stage-3 tooling item (480i-aware capture) lands.

## Stages

1. **Bandwidth probe** (throwaway): ram1 scattered-write + burst-read
   measurement on silicon under ascal load.  ~1 day.
2. **`fb_ddr3.v` adapter**: write FIFO + line prefetch + Avalon
   master, TB-verified against the randomized model.  ~2-3 days.
3. **Integration**: backend mux in fractal_top (BRAM | DDR3 by mode),
   640×480i wiring (coord modes, scanout addressing, OSD value 3,
   new_vmode/boot-grace).  ~2-3 days.
4. **Bring-up + closure**: deploy, verify, SDC additions if the
   adapter cones show up, seed lottery as usual.  ~2-5 days.
5. **480p (31 kHz)**: separate follow-up once 640×480i is soaked.

Realistic total for 640×480i: **1.5-2.5 weeks** — cheaper than the old
SDRAM plan (no controller to build, 480i timing already exists).

## Risks / open questions

- Real-world f2sdram scattered-write throughput under ascal load is
  the only unquantified number → stage 1 measures it before anything
  is built on top.
- ascal contention spikes (mode changes, OSD fades) vs line prefetch:
  the 64 µs margin should swallow them; the underrun diagnostic flag
  proves it on silicon.
- ALM cost of the adapter (~500-1000 ALMs est.) on top of 84% — fine
  on paper; the seed lottery has recovered from worse.
- 480p PLL/timing details deliberately unscoped here.
